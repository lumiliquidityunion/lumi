/// MMT V3 native-settlement adapter.
///
/// The user owns this receipt; the embedded MMT position is only usable through
/// LUMI.  MMT rewards are claimed in their native asset for the first release.
/// A LUMI conversion route is deliberately withheld until an on-chain quote is
/// available.  This keeps a withdrawal independent of an off-chain price.
module lumi::mmt_adapter {
    use lumi::revenue::{Self, RevenueVault};
    use lumi::router::{Self, Router};
    use mmt_v3::collect;
    use mmt_v3::i32::{Self, I32};
    use mmt_v3::liquidity;
    use mmt_v3::pool::{Self, Pool};
    use mmt_v3::position::{Self, Position};
    use mmt_v3::version::Version;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const E_ZERO_INPUT: u64 = 1;
    const E_NATIVE_ROUTE_ONLY: u64 = 2;

    /// User-held receipt and contract-gated MMT position custody.
    public struct MmtPosition<phantom CoinTypeX, phantom CoinTypeY> has key, store {
        id: UID,
        farm_id: u64,
        settlement_route: u8,
        mmt_position: Position,
    }

    public struct PositionOpened has copy, drop {
        farm_id: u64,
        mmt_position_id: sui::object::ID,
        max_amount_x: u64,
        max_amount_y: u64,
    }

    public struct PositionClosed has copy, drop {
        farm_id: u64,
        principal_x: u64,
        principal_y: u64,
        fee_x: u64,
        fee_y: u64,
    }

    public struct NativeRewardClaimed has copy, drop {
        farm_id: u64,
        reward_amount: u64,
        operations_fee: u64,
        protocol_fee: u64,
    }

    /// Opens an MMT position. Tick values are supplied as magnitude plus sign
    /// so the DApp never relies on a two's-complement encoding in PTB input.
    /// MMT returns any unused input and this adapter transfers it to the user.
    public entry fun open_position_native<CoinTypeX, CoinTypeY>(
        router: &Router,
        pool: &mut Pool<CoinTypeX, CoinTypeY>,
        version: &Version,
        farm_id: u64,
        settlement_route: u8,
        tick_lower_magnitude: u32,
        tick_lower_negative: bool,
        tick_upper_magnitude: u32,
        tick_upper_negative: bool,
        coin_x: Coin<CoinTypeX>,
        coin_y: Coin<CoinTypeY>,
        min_amount_x: u64,
        min_amount_y: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
        // The LUMI settlement option is not enabled for MMT until it has a
        // protected on-chain quote; do not accept an unenforceable promise.
        assert!(settlement_route == router::route_native(), E_NATIVE_ROUTE_ONLY);
        let max_amount_x = coin::value(&coin_x);
        let max_amount_y = coin::value(&coin_y);
        assert!(max_amount_x > 0 && max_amount_y > 0, E_ZERO_INPUT);

        let mut mmt_position = liquidity::open_position(
            pool,
            signed_tick(tick_lower_magnitude, tick_lower_negative),
            signed_tick(tick_upper_magnitude, tick_upper_negative),
            version,
            ctx,
        );
        let position_id = object::id(&mmt_position);
        let (refund_x, refund_y) = liquidity::add_liquidity(
            pool, &mut mmt_position, coin_x, coin_y, min_amount_x, min_amount_y, clock, version, ctx,
        );
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(refund_x, sender);
        transfer::public_transfer(refund_y, sender);
        transfer::public_transfer(MmtPosition<CoinTypeX, CoinTypeY> {
            id: object::new(ctx), farm_id, settlement_route, mmt_position,
        }, sender);
        event::emit(PositionOpened { farm_id, mmt_position_id: position_id, max_amount_x, max_amount_y });
    }

    /// Adds liquidity to an existing LUMI-managed MMT position. MMT refunds
    /// unused input, which is returned directly to the receipt holder.
    public entry fun add_liquidity<CoinTypeX, CoinTypeY>(
        router: &Router,
        pool: &mut Pool<CoinTypeX, CoinTypeY>,
        version: &Version,
        position: &mut MmtPosition<CoinTypeX, CoinTypeY>,
        coin_x: Coin<CoinTypeX>,
        coin_y: Coin<CoinTypeY>,
        min_amount_x: u64,
        min_amount_y: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        assert!(coin::value(&coin_x) > 0 && coin::value(&coin_y) > 0, E_ZERO_INPUT);
        let (refund_x, refund_y) = liquidity::add_liquidity(
            pool, &mut position.mmt_position, coin_x, coin_y, min_amount_x, min_amount_y, clock, version, ctx,
        );
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(refund_x, sender);
        transfer::public_transfer(refund_y, sender);
    }

    /// Claims one configured MMT reward type. The DApp must call this once for
    /// each reward type configured in the selected pool before it closes the
    /// receipt. The 2.5% native route fee is split 2% to its typed vault and
    /// 0.5% to operations; all rounding remains with the user.
    public entry fun claim_native_reward<CoinTypeX, CoinTypeY, RewardCoin>(
        router: &Router,
        pool: &mut Pool<CoinTypeX, CoinTypeY>,
        version: &Version,
        position: &mut MmtPosition<CoinTypeX, CoinTypeY>,
        protocol_revenue_vault: &mut RevenueVault<RewardCoin>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        let mut reward = collect::reward<CoinTypeX, CoinTypeY, RewardCoin>(
            pool, &mut position.mmt_position, clock, version, ctx,
        );
        let reward_amount = coin::value(&reward);
        let (operations_fee, protocol_fee) = router::native_reward_fees(reward_amount);
        let operations = coin::split(&mut reward, operations_fee, ctx);
        let protocol = coin::split(&mut reward, protocol_fee, ctx);
        revenue::deposit_coin(protocol_revenue_vault, protocol);
        transfer::public_transfer(reward, tx_context::sender(ctx));
        if (operations_fee > 0) {
            transfer::public_transfer(operations, router::operations_wallet(router));
        } else coin::destroy_zero(operations);
        event::emit(NativeRewardClaimed {
            farm_id: position.farm_id, reward_amount, operations_fee, protocol_fee,
        });
    }

    /// Removes all liquidity, claims trading fees, and closes the MMT receipt.
    /// Claim every configured MMT incentive first; MMT will reject closing a
    /// non-empty position, which is intentional protection against lost rewards.
    public entry fun close_native<CoinTypeX, CoinTypeY>(
        router: &Router,
        pool: &mut Pool<CoinTypeX, CoinTypeY>,
        version: &Version,
        position: MmtPosition<CoinTypeX, CoinTypeY>,
        min_amount_x: u64,
        min_amount_y: u64,
        vault_x: &mut RevenueVault<CoinTypeX>,
        vault_y: &mut RevenueVault<CoinTypeY>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let MmtPosition { id, farm_id, settlement_route: _, mut mmt_position } = position;
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
        let liquidity_amount = position::liquidity(&mmt_position);
        let (principal_x, principal_y) = liquidity::remove_liquidity(
            pool, &mut mmt_position, liquidity_amount, min_amount_x, min_amount_y, clock, version, ctx,
        );
        let principal_x_value = coin::value(&principal_x);
        let principal_y_value = coin::value(&principal_y);
        let (mut fees_x, mut fees_y) = collect::fee(pool, &mut mmt_position, clock, version, ctx);
        let fee_x = coin::value(&fees_x);
        let fee_y = coin::value(&fees_y);
        let (operations_x, protocol_x) = split_native_fees(&mut fees_x, ctx);
        let (operations_y, protocol_y) = split_native_fees(&mut fees_y, ctx);
        revenue::deposit_coin(vault_x, protocol_x);
        revenue::deposit_coin(vault_y, protocol_y);
        liquidity::close_position(mmt_position, version, ctx);
        object::delete(id);

        let sender = tx_context::sender(ctx);
        let operations_wallet = router::operations_wallet(router);
        transfer::public_transfer(principal_x, sender);
        transfer::public_transfer(principal_y, sender);
        transfer::public_transfer(fees_x, sender);
        transfer::public_transfer(fees_y, sender);
        if (coin::value(&operations_x) > 0) transfer::public_transfer(operations_x, operations_wallet) else coin::destroy_zero(operations_x);
        if (coin::value(&operations_y) > 0) transfer::public_transfer(operations_y, operations_wallet) else coin::destroy_zero(operations_y);
        event::emit(PositionClosed { farm_id, principal_x: principal_x_value, principal_y: principal_y_value, fee_x, fee_y });
    }

    fun signed_tick(magnitude: u32, negative: bool): I32 {
        if (negative) i32::neg_from(magnitude) else i32::from(magnitude)
    }

    fun split_native_fees<CoinType>(
        fees: &mut Coin<CoinType>, ctx: &mut TxContext,
    ): (Coin<CoinType>, Coin<CoinType>) {
        let (operations_fee, protocol_fee) = router::native_reward_fees(coin::value(fees));
        let operations = coin::split(fees, operations_fee, ctx);
        let protocol = coin::split(fees, protocol_fee, ctx);
        (operations, protocol)
    }
}
