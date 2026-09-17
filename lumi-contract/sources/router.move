/// LUMI V2 foundation.
///
/// This module is deliberately custody-neutral: it records the approved
/// farm list and settlement economics, but it does not accept principal,
/// make external swaps, or call a venue until the individual venue adapter
/// has been reviewed and tested.
module lumi::router {
    use lumi::lumi::AdminCap;
    use sui::event;
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::vector;

    const E_PAUSED: u64 = 1;
    const E_BAD_ROUTE: u64 = 2;
    const E_BAD_FARM: u64 = 3;
    const E_BAD_ADDRESS: u64 = 4;
    const E_DUPLICATE_POOL: u64 = 5;

    /// One hundred basis points is one percent.
    const BPS_DENOMINATOR: u64 = 10_000;
    const NATIVE_TOTAL_FEE_BPS: u64 = 250;
    const OPERATIONS_FEE_BPS: u64 = 50;
    const PROTOCOL_LIQUIDITY_FEE_BPS: u64 = 200;
    const LUMI_CLAIM_FEE_BPS: u64 = 50;

    const ROUTE_NATIVE: u8 = 0;
    const ROUTE_LUMI_CLAIM: u8 = 1;

    /// A listed external farm. A venue adapter must require the supplied pool
    /// object's ID to match this immutable allow-list value.
    public struct Farm has copy, drop, store {
        id: u64,
        venue: vector<u8>,
        pool_id: ID,
        fee_bps: u64,
        active: bool,
    }

    /// One shared configuration object for the LUMI settlement system.
    public struct Router has key {
        id: UID,
        operations_wallet: address,
        paused: bool,
        next_farm_id: u64,
        farms: vector<Farm>,
    }

    public struct RouterCreated has copy, drop {
        operations_wallet: address,
    }

    public struct FarmListed has copy, drop {
        farm_id: u64,
        venue: vector<u8>,
        pool_id: ID,
        fee_bps: u64,
    }

    public struct FarmStatusChanged has copy, drop {
        farm_id: u64,
        active: bool,
    }

    public struct RouterPaused has copy, drop {
        paused: bool,
    }

    public struct OperationsWalletChanged has copy, drop {
        previous: address,
        next: address,
    }

    /// Create the V2 router once. Possession of the genesis AdminCap is the
    /// authority check; AdminCap cannot be forged outside lumi::lumi.
    public entry fun create_router(
        _admin: &AdminCap,
        operations_wallet: address,
        ctx: &mut TxContext,
    ) {
        assert!(operations_wallet != @0x0, E_BAD_ADDRESS);
        transfer::share_object(Router {
            id: object::new(ctx),
            operations_wallet,
            paused: false,
            next_farm_id: 0,
            farms: vector[],
        });
        event::emit(RouterCreated { operations_wallet });
    }

    /// Add one reviewed venue pool. Calls to a venue are intentionally absent
    /// here; a later Cetus/Bluefin adapter must enforce the exact pool types.
    public entry fun list_farm(
        router: &mut Router,
        _admin: &AdminCap,
        venue: vector<u8>,
        pool_id: ID,
        fee_bps: u64,
    ) {
        assert!(!router.paused, E_PAUSED);
        assert!(vector::length(&venue) > 0, E_BAD_FARM);
        assert!(!contains_pool(&router.farms, &pool_id), E_DUPLICATE_POOL);

        let farm_id = router.next_farm_id;
        router.next_farm_id = farm_id + 1;
        vector::push_back(&mut router.farms, Farm {
            id: farm_id,
            venue,
            pool_id,
            fee_bps,
            active: true,
        });
        let farm = *vector::borrow(&router.farms, vector::length(&router.farms) - 1);
        event::emit(FarmListed {
            farm_id,
            venue: farm.venue,
            pool_id: farm.pool_id,
            fee_bps,
        });
    }

    public entry fun set_farm_active(
        router: &mut Router,
        _admin: &AdminCap,
        farm_id: u64,
        active: bool,
    ) {
        let farm = borrow_farm_mut(router, farm_id);
        farm.active = active;
        event::emit(FarmStatusChanged { farm_id, active });
    }

    public entry fun set_paused(router: &mut Router, _admin: &AdminCap, paused: bool) {
        router.paused = paused;
        event::emit(RouterPaused { paused });
    }

    public entry fun set_operations_wallet(
        router: &mut Router,
        _admin: &AdminCap,
        next: address,
    ) {
        assert!(next != @0x0, E_BAD_ADDRESS);
        let previous = router.operations_wallet;
        router.operations_wallet = next;
        event::emit(OperationsWalletChanged { previous, next });
    }

    public fun is_paused(router: &Router): bool { router.paused }
    public fun operations_wallet(router: &Router): address { router.operations_wallet }
    public fun farm_count(router: &Router): u64 { vector::length(&router.farms) }
    public fun farm(router: &Router, farm_id: u64): Farm {
        *vector::borrow(&router.farms, farm_index(&router.farms, farm_id))
    }
    public fun is_farm_active(router: &Router, farm_id: u64): bool {
        farm(router, farm_id).active
    }
    public fun assert_active_farm_pool(router: &Router, farm_id: u64, pool_id: ID) {
        assert!(!router.paused, E_PAUSED);
        let listed = farm(router, farm_id);
        assert!(listed.active && listed.pool_id == pool_id, E_BAD_FARM);
    }

    public fun route_native(): u8 { ROUTE_NATIVE }
    public fun route_lumi_claim(): u8 { ROUTE_LUMI_CLAIM }
    public fun native_total_fee_bps(): u64 { NATIVE_TOTAL_FEE_BPS }
    public fun operations_fee_bps(): u64 { OPERATIONS_FEE_BPS }
    public fun protocol_liquidity_fee_bps(): u64 { PROTOCOL_LIQUIDITY_FEE_BPS }
    public fun lumi_claim_fee_bps(): u64 { LUMI_CLAIM_FEE_BPS }

    /// Returns (operations_fee, protocol_liquidity_fee) for a native claim.
    /// Fees are calculated only from the reward amount supplied by an adapter.
    public fun native_reward_fees(reward_amount: u64): (u64, u64) {
        (fee_for_bps(reward_amount, OPERATIONS_FEE_BPS),
         fee_for_bps(reward_amount, PROTOCOL_LIQUIDITY_FEE_BPS))
    }

    /// Returns the operations-only fee for an opted-in LUMI claim.
    public fun lumi_claim_fee(reward_amount: u64): u64 {
        fee_for_bps(reward_amount, LUMI_CLAIM_FEE_BPS)
    }

    public fun assert_route(route: u8) {
        assert!(route == ROUTE_NATIVE || route == ROUTE_LUMI_CLAIM, E_BAD_ROUTE);
    }

    fun fee_for_bps(amount: u64, bps: u64): u64 {
        // This avoids overflow for large u64 reward amounts.
        (amount / BPS_DENOMINATOR) * bps
            + ((amount % BPS_DENOMINATOR) * bps) / BPS_DENOMINATOR
    }

    fun contains_pool(farms: &vector<Farm>, pool_id: &ID): bool {
        let mut i = 0;
        while (i < vector::length(farms)) {
            if (vector::borrow(farms, i).pool_id == *pool_id) return true;
            i = i + 1;
        };
        false
    }

    fun farm_index(farms: &vector<Farm>, farm_id: u64): u64 {
        let mut i = 0;
        while (i < vector::length(farms)) {
            if (vector::borrow(farms, i).id == farm_id) return i;
            i = i + 1;
        };
        abort E_BAD_FARM
    }

    fun borrow_farm_mut(router: &mut Router, farm_id: u64): &mut Farm {
        let index = farm_index(&router.farms, farm_id);
        vector::borrow_mut(&mut router.farms, index)
    }

    #[test]
    fun native_fee_split_is_exact_at_one_hundred_units() {
        let (operations, protocol) = native_reward_fees(10_000);
        assert!(operations == 50, 0);
        assert!(protocol == 200, 1);
        assert!(operations + protocol == 250, 2);
    }

    #[test]
    fun lumi_claim_fee_is_half_percent() {
        assert!(lumi_claim_fee(10_000) == 50, 0);
    }

    #[test]
    fun small_rewards_round_down_without_overcharging() {
        let (operations, protocol) = native_reward_fees(99);
        assert!(operations == 0 && protocol == 1, 0);
        assert!(operations + protocol <= 99, 1);
    }
}
