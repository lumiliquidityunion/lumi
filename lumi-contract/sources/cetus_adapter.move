/// Cetus V2 native-settlement adapter.
///
/// It supports one custody model: the user owns this LUMI receipt object,
/// while the embedded Cetus position is inaccessible except through this
/// module. The LUMI-claim conversion route is intentionally not exposed here.
module lumi::cetus_adapter {
    use cetus_clmm::config::GlobalConfig;
    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::position::{Self, Position};
    use cetus_clmm::rewarder::RewarderGlobalVault;
    use lumi::lumi::{Self, AdminCap, LUMI, Vault};
    use lumi::revenue::{Self, RevenueVault};
    use lumi::router::{Self, Router};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const E_ZERO_INPUT: u64 = 1;
    const E_MAX_INPUT: u64 = 2;

    /// User-held LUMI receipt and contract-gated Cetus position custody.
    public struct CetusPosition<phantom CoinTypeA, phantom CoinTypeB> has key, store {
        id: UID,
        farm_id: u64,
        settlement_route: u8,
        cetus_position: Position,
    }

    public struct PositionOpened has copy, drop {
        farm_id: u64,
        cetus_position_id: sui::object::ID,
        amount_a: u64,
        amount_b: u64,
    }

    public struct PositionClosed has copy, drop {
        farm_id: u64,
        principal_a: u64,
        principal_b: u64,
        fee_a: u64,
        fee_b: u64,
    }

    public struct NativeRewardClaimed has copy, drop {
        farm_id: u64,
        reward_amount: u64,
        operations_fee: u64,
        protocol_fee: u64,
    }

    /// Opens a managed Cetus position using all of `coin_a` as the fixed
    /// input and `coin_b` as the maximum opposing input. Any unused coin_b is
    /// returned to the transaction sender, providing max-input protection.
    public entry fun open_position<CoinTypeA, CoinTypeB>(
        router: &Router,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        farm_id: u64,
        settlement_route: u8,
        tick_lower: u32,
        tick_upper: u32,
        mut coin_a: Coin<CoinTypeA>,
        mut coin_b: Coin<CoinTypeB>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
        router::assert_route(settlement_route);
        let max_a = coin::value(&coin_a);
        let max_b = coin::value(&coin_b);
        assert!(max_a > 0 && max_b > 0, E_ZERO_INPUT);

        let mut position = pool::open_position(config, pool, tick_lower, tick_upper, ctx);
        let receipt = pool::add_liquidity_fix_coin(config, pool, &mut position, max_a, true, clock);
        let (amount_a, amount_b) = pool::add_liquidity_pay_amount(&receipt);
        assert!(amount_a <= max_a && amount_b <= max_b, E_MAX_INPUT);
        let pay_a = coin::into_balance(coin::split(&mut coin_a, amount_a, ctx));
        let pay_b = coin::into_balance(coin::split(&mut coin_b, amount_b, ctx));
        pool::repay_add_liquidity(config, pool, pay_a, pay_b, receipt);

        let position_id = object::id(&position);
        let sender = tx_context::sender(ctx);
        if (coin::value(&coin_a) > 0) transfer::public_transfer(coin_a, sender) else coin::destroy_zero(coin_a);
        if (coin::value(&coin_b) > 0) transfer::public_transfer(coin_b, sender) else coin::destroy_zero(coin_b);
        transfer::public_transfer(CetusPosition<CoinTypeA, CoinTypeB> {
            id: object::new(ctx), farm_id, settlement_route, cetus_position: position,
        }, sender);
        event::emit(PositionOpened { farm_id, cetus_position_id: position_id, amount_a, amount_b });
    }

    /// Closes the user-held receipt, returns principal, and splits only Cetus
    /// trading fees into 0.5% operations and 2.0% typed revenue vaults.
    public entry fun close_native<CoinTypeA, CoinTypeB>(
        router: &Router,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        position: CetusPosition<CoinTypeA, CoinTypeB>,
        min_amount_a: u64,
        min_amount_b: u64,
        vault_a: &mut RevenueVault<CoinTypeA>,
        vault_b: &mut RevenueVault<CoinTypeB>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let CetusPosition { id, farm_id, settlement_route, mut cetus_position } = position;
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
        assert!(settlement_route == router::route_native(), E_MAX_INPUT);
        let liquidity = position::liquidity(&cetus_position);
        let (principal_a, principal_b) = if (liquidity > 0) {
            pool::remove_liquidity_with_slippage(
                config, pool, &mut cetus_position, liquidity, min_amount_a, min_amount_b, clock,
            )
        } else (balance::zero<CoinTypeA>(), balance::zero<CoinTypeB>());
        let principal_a_value = balance::value(&principal_a);
        let principal_b_value = balance::value(&principal_b);
        let (mut fees_a, mut fees_b) = pool::collect_fee(config, pool, &cetus_position, false);
        let fee_a = balance::value(&fees_a);
        let fee_b = balance::value(&fees_b);
        let (ops_a, protocol_a) = split_native_fees(&mut fees_a);
        let (ops_b, protocol_b) = split_native_fees(&mut fees_b);
        revenue::deposit(vault_a, protocol_a);
        revenue::deposit(vault_b, protocol_b);
        pool::close_position(config, pool, cetus_position);
        object::delete(id);

        let sender = tx_context::sender(ctx);
        let ops = router::operations_wallet(router);
        transfer::public_transfer(coin::from_balance(principal_a, ctx), sender);
        transfer::public_transfer(coin::from_balance(principal_b, ctx), sender);
        transfer::public_transfer(coin::from_balance(fees_a, ctx), sender);
        transfer::public_transfer(coin::from_balance(fees_b, ctx), sender);
        if (balance::value(&ops_a) > 0) transfer::public_transfer(coin::from_balance(ops_a, ctx), ops) else balance::destroy_zero(ops_a);
        if (balance::value(&ops_b) > 0) transfer::public_transfer(coin::from_balance(ops_b, ctx), ops) else balance::destroy_zero(ops_b);
        event::emit(PositionClosed {
            farm_id, principal_a: principal_a_value, principal_b: principal_b_value, fee_a, fee_b,
        });
    }

    /// Claim a Cetus incentive reward in its native coin. The caller must
    /// supply Cetus's shared RewarderGlobalVault and the matching LUMI typed
    /// revenue vault. This is intentionally separate from LUMI conversion.
    public entry fun claim_native_reward<CoinTypeA, CoinTypeB, RewardCoin>(
        router: &Router,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        position: &mut CetusPosition<CoinTypeA, CoinTypeB>,
        cetus_reward_vault: &mut RewarderGlobalVault,
        protocol_revenue_vault: &mut RevenueVault<RewardCoin>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        assert!(position.settlement_route == router::route_native(), E_MAX_INPUT);
        let mut reward = pool::collect_reward<CoinTypeA, CoinTypeB, RewardCoin>(
            config, pool, &position.cetus_position, cetus_reward_vault, true, clock,
        );
        let reward_amount = balance::value(&reward);
        let (operations_fee, protocol_fee) = router::native_reward_fees(reward_amount);
        let operations = balance::split(&mut reward, operations_fee);
        let protocol = balance::split(&mut reward, protocol_fee);
        revenue::deposit(protocol_revenue_vault, protocol);
        let sender = tx_context::sender(ctx);
        let operations_wallet = router::operations_wallet(router);
        transfer::public_transfer(coin::from_balance(reward, ctx), sender);
        if (operations_fee > 0) {
            transfer::public_transfer(coin::from_balance(operations, ctx), operations_wallet)
        } else balance::destroy_zero(operations);
        event::emit(NativeRewardClaimed {
            farm_id: position.farm_id, reward_amount, operations_fee, protocol_fee,
        });
    }

    /// Guarded test route for the LUMI reward option. The receipt must have
    /// been opened with `router::route_lumi_claim()`. It retains the entire
    /// native reward in the protocol vault and pays a manually quoted amount
    /// of fixed-reserve LUMI, minus the 0.5% operations fee. `min_lumi_out`
    /// is the user's on-chain protection against an undersized quote.
    ///
    /// This is deliberately admin-executed for the operations-wallet test
    /// phase. Do not expose it as public production settlement until a
    /// TWAP/oracle quote replaces `gross_lumi_amount`.
    public entry fun claim_lumi_reward_for_test<CoinTypeA, CoinTypeB, RewardCoin>(
        router: &Router,
        admin: &AdminCap,
        lumi_vault: &mut Vault,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        position: &mut CetusPosition<CoinTypeA, CoinTypeB>,
        cetus_reward_vault: &mut RewarderGlobalVault,
        retained_reward_vault: &mut RevenueVault<RewardCoin>,
        gross_lumi_amount: u64,
        min_lumi_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        assert!(position.settlement_route == router::route_lumi_claim(), E_MAX_INPUT);
        let reward = pool::collect_reward<CoinTypeA, CoinTypeB, RewardCoin>(
            config, pool, &position.cetus_position, cetus_reward_vault, true, clock,
        );
        revenue::deposit(retained_reward_vault, reward);
        let mut gross_lumi = lumi::withdraw_lumi_reserve(lumi_vault, admin, gross_lumi_amount, ctx);
        let operations_fee = router::lumi_claim_fee(gross_lumi_amount);
        let operations = coin::split(&mut gross_lumi, operations_fee, ctx);
        assert!(coin::value(&gross_lumi) >= min_lumi_out, E_MAX_INPUT);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(gross_lumi, sender);
        if (operations_fee > 0) {
            transfer::public_transfer(operations, router::operations_wallet(router))
        } else coin::destroy_zero(operations);
    }

    fun split_native_fees<CoinType>(fees: &mut Balance<CoinType>): (Balance<CoinType>, Balance<CoinType>) {
        let amount = balance::value(fees);
        let (operations_fee, protocol_fee) = router::native_reward_fees(amount);
        let operations = balance::split(fees, operations_fee);
        let protocol = balance::split(fees, protocol_fee);
        (operations, protocol)
    }
}
