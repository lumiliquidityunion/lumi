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
    use lumi::price_oracle::{Self, PriceOracle};
    use lumi::revenue::{Self, RevenueVault};
    use lumi::router::{Self, Router};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::dynamic_field;
    use sui::event;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::sui::SUI;

    const E_ZERO_INPUT: u64 = 1;
    const E_MAX_INPUT: u64 = 2;

    /// Internal accounting has one million sub-units per on-chain LUMI cent.
    /// This preserves small reward and fee fractions despite LUMI's 2 decimals.
    const LUMI_CREDIT_SCALE: u64 = 1_000_000;

    /// User-held LUMI receipt and contract-gated Cetus position custody.
    public struct CetusPosition<phantom CoinTypeA, phantom CoinTypeB> has key, store {
        id: UID,
        farm_id: u64,
        settlement_route: u8,
        cetus_position: Position,
    }

    /// Dynamic-field key so this V3 accounting can be added to V2 receipts
    /// without changing their on-chain struct layout.
    public struct LumiCreditKey has copy, drop, store {}

    public struct LumiCredit has store {
        user_units: u64,
        operations_units: u64,
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

    public struct LumiRewardSettled has copy, drop {
        farm_id: u64,
        native_reward: u64,
        gross_lumi: u64,
        user_lumi: u64,
        operations_lumi: u64,
        used_native_fallback: bool,
    }

    /// Full-position LUMI settlement is deliberately restricted to a
    /// CoinTypeA/SUI Cetus receipt. CoinTypeA is valued into SUI using its
    /// own pool-bound oracle, then the total SUI value is converted to LUMI
    /// against the independent LUMI/SUI oracle. The venue assets remain in
    /// their typed revenue vaults; this function never sells a user's assets
    /// through an unbounded external swap.
    public struct PositionSettledInLumi has copy, drop {
        farm_id: u64,
        retained_a: u64,
        retained_sui: u64,
        gross_lumi: u64,
        user_lumi: u64,
        operations_lumi: u64,
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

    /// Closes either settlement route, returns principal, and splits Cetus
    /// trading fees into 0.5% operations and 2.0% typed revenue vaults.
    /// Claim outstanding incentives before calling this function; route choice
    /// can never prevent the principal from being withdrawn.
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
        let CetusPosition { id, farm_id, settlement_route: _, mut cetus_position } = position;
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
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

    /// Atomically close a LUMI-route CoinTypeA/SUI receipt and settle every
    /// recovered principal and trading fee in LUMI. The caller supplies
    /// normal Cetus minimum return amounts plus `min_lumi_out`; an unavailable
    /// or manipulated oracle aborts before the position is touched, so the
    /// user can instead use `close_native`.
    ///
    /// Outstanding incentive rewards must be claimed first through their
    /// dedicated reward route. This avoids treating an unpriced third reward
    /// coin as if it were principal.
    public entry fun close_position_for_lumi<CoinTypeA>(
        router: &Router,
        lumi_vault: &mut Vault,
        lumi_oracle: &PriceOracle,
        lumi_sui_pool: &Pool<LUMI, SUI>,
        asset_sui_oracle: &price_oracle::CetusPairOracle<CoinTypeA, SUI>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, SUI>,
        position: CetusPosition<CoinTypeA, SUI>,
        min_amount_a: u64,
        min_amount_sui: u64,
        retained_a_vault: &mut RevenueVault<CoinTypeA>,
        retained_sui_vault: &mut RevenueVault<SUI>,
        min_lumi_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let CetusPosition { id, farm_id, settlement_route, mut cetus_position } = position;
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
        assert!(settlement_route == router::route_lumi_claim(), E_MAX_INPUT);

        // Both quotes are read and guarded before venue state is mutated.
        assert!(price_oracle::is_twap_ready(lumi_oracle, 300, clock), E_MAX_INPUT);
        let lumi_twap = price_oracle::twap_sqrt_price(lumi_oracle, 300, clock);
        let lumi_spot = pool::current_sqrt_price(lumi_sui_pool);
        assert!(price_oracle::is_spot_within_twap_deviation(lumi_spot, lumi_twap), E_MAX_INPUT);
        let asset_twap = price_oracle::cetus_pair_twap_sqrt_price(asset_sui_oracle, 300, clock);
        let asset_spot = pool::current_sqrt_price(pool);
        assert!(price_oracle::is_spot_within_twap_deviation(asset_spot, asset_twap), E_MAX_INPUT);

        let liquidity = position::liquidity(&cetus_position);
        let (principal_a, principal_sui) = if (liquidity > 0) {
            pool::remove_liquidity_with_slippage(
                config, pool, &mut cetus_position, liquidity, min_amount_a, min_amount_sui, clock,
            )
        } else (balance::zero<CoinTypeA>(), balance::zero<SUI>());
        let (fees_a, fees_sui) = pool::collect_fee(config, pool, &cetus_position, false);
        pool::close_position(config, pool, cetus_position);
        object::delete(id);

        let retained_a = balance::value(&principal_a) + balance::value(&fees_a);
        let retained_sui = balance::value(&principal_sui) + balance::value(&fees_sui);
        let a_value_in_sui = price_oracle::quote_a_to_b(retained_a, asset_twap);
        let gross_lumi = price_oracle::quote_b_to_a(retained_sui + a_value_in_sui, lumi_twap);
        assert!(gross_lumi > 0, E_ZERO_INPUT);
        let operations_lumi = router::lumi_claim_fee(gross_lumi);
        let mut user_payout = lumi::withdraw_lumi_for_settlement(lumi_vault, gross_lumi, ctx);
        let operations = coin::split(&mut user_payout, operations_lumi, ctx);
        let user_lumi = coin::value(&user_payout);
        assert!(user_lumi >= min_lumi_out, E_MAX_INPUT);

        revenue::deposit(retained_a_vault, principal_a);
        revenue::deposit(retained_a_vault, fees_a);
        revenue::deposit(retained_sui_vault, principal_sui);
        revenue::deposit(retained_sui_vault, fees_sui);
        transfer::public_transfer(user_payout, tx_context::sender(ctx));
        if (operations_lumi > 0) transfer::public_transfer(operations, router::operations_wallet(router)) else coin::destroy_zero(operations);
        event::emit(PositionSettledInLumi {
            farm_id, retained_a, retained_sui, gross_lumi, user_lumi, operations_lumi,
        });
    }

    /// Full LUMI close for a listed CoinTypeA/SUI farm with both its external
    /// reward coin and its SUI reward enabled. Every recovered asset is valued
    /// only through its own pool-bound five-minute oracle before it is retained
    /// in the matching vault; the user receives the total guarded value in
    /// LUMI less the selected-route 0.5% operations fee.
    public entry fun close_position_and_rewards_for_lumi<CoinTypeA, RewardCoin>(
        router: &Router,
        lumi_vault: &mut Vault,
        lumi_oracle: &PriceOracle,
        lumi_sui_pool: &Pool<LUMI, SUI>,
        asset_sui_oracle: &price_oracle::CetusPairOracle<CoinTypeA, SUI>,
        reward_sui_oracle: &price_oracle::CetusPairOracle<RewardCoin, SUI>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, SUI>,
        position: CetusPosition<CoinTypeA, SUI>,
        cetus_reward_vault: &mut RewarderGlobalVault,
        min_amount_a: u64,
        min_amount_sui: u64,
        retained_a_vault: &mut RevenueVault<CoinTypeA>,
        retained_sui_vault: &mut RevenueVault<SUI>,
        retained_reward_vault: &mut RevenueVault<RewardCoin>,
        min_lumi_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let CetusPosition { id, farm_id, settlement_route, mut cetus_position } = position;
        router::assert_active_farm_pool(router, farm_id, object::id(pool));
        assert!(settlement_route == router::route_lumi_claim(), E_MAX_INPUT);

        assert!(price_oracle::is_twap_ready(lumi_oracle, 300, clock), E_MAX_INPUT);
        let lumi_twap = price_oracle::twap_sqrt_price(lumi_oracle, 300, clock);
        assert!(price_oracle::is_spot_within_twap_deviation(pool::current_sqrt_price(lumi_sui_pool), lumi_twap), E_MAX_INPUT);
        let asset_twap = price_oracle::cetus_pair_twap_sqrt_price(asset_sui_oracle, 300, clock);
        assert!(price_oracle::is_spot_within_twap_deviation(pool::current_sqrt_price(pool), asset_twap), E_MAX_INPUT);
        let reward_twap = price_oracle::cetus_pair_twap_sqrt_price(reward_sui_oracle, 300, clock);

        let reward = pool::collect_reward<CoinTypeA, SUI, RewardCoin>(
            config, pool, &cetus_position, cetus_reward_vault, true, clock,
        );
        let reward_sui = pool::collect_reward<CoinTypeA, SUI, SUI>(
            config, pool, &cetus_position, cetus_reward_vault, true, clock,
        );
        let liquidity = position::liquidity(&cetus_position);
        let (principal_a, principal_sui) = if (liquidity > 0) {
            pool::remove_liquidity_with_slippage(
                config, pool, &mut cetus_position, liquidity, min_amount_a, min_amount_sui, clock,
            )
        } else (balance::zero<CoinTypeA>(), balance::zero<SUI>());
        let (fees_a, fees_sui) = pool::collect_fee(config, pool, &cetus_position, false);
        pool::close_position(config, pool, cetus_position);
        object::delete(id);

        let retained_a = balance::value(&principal_a) + balance::value(&fees_a);
        let retained_sui = balance::value(&principal_sui) + balance::value(&fees_sui) + balance::value(&reward_sui);
        let retained_reward = balance::value(&reward);
        let a_value_in_sui = price_oracle::quote_a_to_b(retained_a, asset_twap);
        let reward_value_in_sui = price_oracle::quote_a_to_b(retained_reward, reward_twap);
        let gross_lumi = price_oracle::quote_b_to_a(retained_sui + a_value_in_sui + reward_value_in_sui, lumi_twap);
        assert!(gross_lumi > 0, E_ZERO_INPUT);
        let operations_lumi = router::lumi_claim_fee(gross_lumi);
        let mut user_payout = lumi::withdraw_lumi_for_settlement(lumi_vault, gross_lumi, ctx);
        let operations = coin::split(&mut user_payout, operations_lumi, ctx);
        let user_lumi = coin::value(&user_payout);
        assert!(user_lumi >= min_lumi_out, E_MAX_INPUT);

        revenue::deposit(retained_a_vault, principal_a);
        revenue::deposit(retained_a_vault, fees_a);
        revenue::deposit(retained_sui_vault, principal_sui);
        revenue::deposit(retained_sui_vault, fees_sui);
        revenue::deposit(retained_sui_vault, reward_sui);
        revenue::deposit(retained_reward_vault, reward);
        transfer::public_transfer(user_payout, tx_context::sender(ctx));
        if (operations_lumi > 0) transfer::public_transfer(operations, router::operations_wallet(router)) else coin::destroy_zero(operations);
        event::emit(PositionSettledInLumi {
            farm_id, retained_a, retained_sui, gross_lumi, user_lumi, operations_lumi,
        });
    }

    /// Atomically claims a configured native Cetus incentive plus a reward in
    /// the pool's coin-B type, then closes the position.
    /// Cetus rejects a close while *any* reward remains outstanding, so this is
    /// the safe production settlement route for listed pools with two rewards.
    public entry fun close_with_native_rewards<
        CoinTypeA, CoinTypeB, RewardCoin0,
    >(
        router: &Router,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        position: CetusPosition<CoinTypeA, CoinTypeB>,
        min_amount_a: u64,
        min_amount_b: u64,
        vault_a: &mut RevenueVault<CoinTypeA>,
        vault_b: &mut RevenueVault<CoinTypeB>,
        cetus_reward_vault: &mut RewarderGlobalVault,
        reward_vault_0: &mut RevenueVault<RewardCoin0>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let CetusPosition { id, farm_id, settlement_route: _, mut cetus_position } = position;
        router::assert_active_farm_pool(router, farm_id, object::id(pool));

        let mut reward_0 = pool::collect_reward<CoinTypeA, CoinTypeB, RewardCoin0>(
            config, pool, &cetus_position, cetus_reward_vault, true, clock,
        );
        let reward_0_amount = balance::value(&reward_0);
        let (reward_0_ops_fee, reward_0_protocol_fee) = router::native_reward_fees(reward_0_amount);
        let reward_0_ops = balance::split(&mut reward_0, reward_0_ops_fee);
        let reward_0_protocol = balance::split(&mut reward_0, reward_0_protocol_fee);
        revenue::deposit(reward_vault_0, reward_0_protocol);

        let mut reward_1 = pool::collect_reward<CoinTypeA, CoinTypeB, CoinTypeB>(
            config, pool, &cetus_position, cetus_reward_vault, true, clock,
        );
        let reward_1_amount = balance::value(&reward_1);
        let (reward_1_ops_fee, reward_1_protocol_fee) = router::native_reward_fees(reward_1_amount);
        let reward_1_ops = balance::split(&mut reward_1, reward_1_ops_fee);
        let reward_1_protocol = balance::split(&mut reward_1, reward_1_protocol_fee);
        revenue::deposit(vault_b, reward_1_protocol);

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
        transfer::public_transfer(coin::from_balance(reward_0, ctx), sender);
        transfer::public_transfer(coin::from_balance(reward_1, ctx), sender);
        if (balance::value(&ops_a) > 0) transfer::public_transfer(coin::from_balance(ops_a, ctx), ops) else balance::destroy_zero(ops_a);
        if (balance::value(&ops_b) > 0) transfer::public_transfer(coin::from_balance(ops_b, ctx), ops) else balance::destroy_zero(ops_b);
        if (reward_0_ops_fee > 0) transfer::public_transfer(coin::from_balance(reward_0_ops, ctx), ops) else balance::destroy_zero(reward_0_ops);
        if (reward_1_ops_fee > 0) transfer::public_transfer(coin::from_balance(reward_1_ops, ctx), ops) else balance::destroy_zero(reward_1_ops);
        event::emit(PositionClosed {
            farm_id, principal_a: principal_a_value, principal_b: principal_b_value, fee_a, fee_b,
        });
        event::emit(NativeRewardClaimed {
            farm_id, reward_amount: reward_0_amount, operations_fee: reward_0_ops_fee, protocol_fee: reward_0_protocol_fee,
        });
        event::emit(NativeRewardClaimed {
            farm_id, reward_amount: reward_1_amount, operations_fee: reward_1_ops_fee, protocol_fee: reward_1_protocol_fee,
        });
    }

    /// Claim a Cetus incentive reward in its native coin. This is also the
    /// route-1 fallback when a LUMI quote is unavailable or below one cent.
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

    /// Permissionless true-value SUI-reward settlement. The receipt gets the
    /// LUMI value implied by the protected LUMI/SUI TWAP, never a guaranteed
    /// dollar value. An unsafe or dust quote settles as native SUI instead.
    public entry fun claim_lumi_sui_reward<CoinTypeA>(
        router: &Router,
        lumi_vault: &mut Vault,
        oracle: &PriceOracle,
        lumi_sui_pool: &Pool<LUMI, SUI>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, SUI>,
        position: &mut CetusPosition<CoinTypeA, SUI>,
        cetus_reward_vault: &mut RewarderGlobalVault,
        retained_sui_vault: &mut RevenueVault<SUI>,
        min_lumi_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        assert!(position.settlement_route == router::route_lumi_claim(), E_MAX_INPUT);
        let mut reward = pool::collect_reward<CoinTypeA, SUI, SUI>(
            config, pool, &position.cetus_position, cetus_reward_vault, true, clock,
        );
        let reward_amount = balance::value(&reward);
        if (!price_oracle::is_twap_ready(oracle, 300, clock)) {
            settle_native_sui_fallback(router, position.farm_id, reward, retained_sui_vault, ctx);
            event::emit(LumiRewardSettled { farm_id: position.farm_id, native_reward: reward_amount, gross_lumi: 0, user_lumi: 0, operations_lumi: 0, used_native_fallback: true });
            return
        };
        let twap = price_oracle::twap_sqrt_price(oracle, 300, clock);
        let spot = pool::current_sqrt_price(lumi_sui_pool);
        if (!price_oracle::is_spot_within_twap_deviation(spot, twap)) {
            settle_native_sui_fallback(router, position.farm_id, reward, retained_sui_vault, ctx);
            event::emit(LumiRewardSettled { farm_id: position.farm_id, native_reward: reward_amount, gross_lumi: 0, user_lumi: 0, operations_lumi: 0, used_native_fallback: true });
            return
        };
        let gross_lumi = price_oracle::quote_b_to_a(reward_amount, twap);
        if (gross_lumi == 0) {
            settle_native_sui_fallback(router, position.farm_id, reward, retained_sui_vault, ctx);
            event::emit(LumiRewardSettled { farm_id: position.farm_id, native_reward: reward_amount, gross_lumi: 0, user_lumi: 0, operations_lumi: 0, used_native_fallback: true });
            return
        };
        revenue::deposit(retained_sui_vault, reward);
        let operations_lumi = router::lumi_claim_fee(gross_lumi);
        let mut payout = lumi::withdraw_lumi_for_settlement(lumi_vault, gross_lumi, ctx);
        let operations = coin::split(&mut payout, operations_lumi, ctx);
        let user_lumi = coin::value(&payout);
        assert!(user_lumi >= min_lumi_out, E_MAX_INPUT);
        transfer::public_transfer(payout, tx_context::sender(ctx));
        if (operations_lumi > 0) transfer::public_transfer(operations, router::operations_wallet(router)) else coin::destroy_zero(operations);
        event::emit(LumiRewardSettled { farm_id: position.farm_id, native_reward: reward_amount, gross_lumi, user_lumi, operations_lumi, used_native_fallback: false });
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

    /// Adds a proportional top-up to a receipt's existing Cetus position.
    /// It is available to both settlement routes and returns unused inputs.
    public entry fun add_liquidity<CoinTypeA, CoinTypeB>(
        router: &Router,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        position: &mut CetusPosition<CoinTypeA, CoinTypeB>,
        mut coin_a: Coin<CoinTypeA>,
        mut coin_b: Coin<CoinTypeB>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        let max_a = coin::value(&coin_a);
        let max_b = coin::value(&coin_b);
        assert!(max_a > 0 && max_b > 0, E_ZERO_INPUT);
        let receipt = pool::add_liquidity_fix_coin(
            config, pool, &mut position.cetus_position, max_a, true, clock,
        );
        let (amount_a, amount_b) = pool::add_liquidity_pay_amount(&receipt);
        assert!(amount_a <= max_a && amount_b <= max_b, E_MAX_INPUT);
        let pay_a = coin::into_balance(coin::split(&mut coin_a, amount_a, ctx));
        let pay_b = coin::into_balance(coin::split(&mut coin_b, amount_b, ctx));
        pool::repay_add_liquidity(config, pool, pay_a, pay_b, receipt);
        let sender = tx_context::sender(ctx);
        if (coin::value(&coin_a) > 0) transfer::public_transfer(coin_a, sender) else coin::destroy_zero(coin_a);
        if (coin::value(&coin_b) > 0) transfer::public_transfer(coin_b, sender) else coin::destroy_zero(coin_b);
    }

    /// Test-only high-precision LUMI settlement. `quoted_lumi_units` is a
    /// guarded admin quote expressed in sub-cent credit units. A zero quote
    /// invokes the native fallback rather than trapping the user's reward.
    public entry fun accrue_lumi_reward_or_native_for_test<CoinTypeA, CoinTypeB, RewardCoin>(
        router: &Router,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        position: &mut CetusPosition<CoinTypeA, CoinTypeB>,
        cetus_reward_vault: &mut RewarderGlobalVault,
        revenue_vault: &mut RevenueVault<RewardCoin>,
        quoted_lumi_units: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        router::assert_active_farm_pool(router, position.farm_id, object::id(pool));
        assert!(position.settlement_route == router::route_lumi_claim(), E_MAX_INPUT);
        let mut reward = pool::collect_reward<CoinTypeA, CoinTypeB, RewardCoin>(
            config, pool, &position.cetus_position, cetus_reward_vault, true, clock,
        );
        if (quoted_lumi_units == 0) {
            let reward_amount = balance::value(&reward);
            let (operations_fee, protocol_fee) = router::native_reward_fees(reward_amount);
            let operations = balance::split(&mut reward, operations_fee);
            let protocol = balance::split(&mut reward, protocol_fee);
            revenue::deposit(revenue_vault, protocol);
            let sender = tx_context::sender(ctx);
            transfer::public_transfer(coin::from_balance(reward, ctx), sender);
            if (operations_fee > 0) transfer::public_transfer(coin::from_balance(operations, ctx), router::operations_wallet(router)) else balance::destroy_zero(operations);
            event::emit(NativeRewardClaimed { farm_id: position.farm_id, reward_amount, operations_fee, protocol_fee });
        } else {
            revenue::deposit(revenue_vault, reward);
            add_lumi_credit(position, quoted_lumi_units);
        };
    }

    /// Settles every whole LUMI cent from accumulated credits. Fractional
    /// user and operations amounts remain attached to the receipt.
    public entry fun settle_lumi_credit_for_test<CoinTypeA, CoinTypeB>(
        router: &Router,
        admin: &AdminCap,
        lumi_vault: &mut Vault,
        position: &mut CetusPosition<CoinTypeA, CoinTypeB>,
        min_lumi_out: u64,
        ctx: &mut TxContext,
    ) {
        assert!(position.settlement_route == router::route_lumi_claim(), E_MAX_INPUT);
        let credit = borrow_lumi_credit_mut(position);
        let user_amount = credit.user_units / LUMI_CREDIT_SCALE;
        let operations_amount = credit.operations_units / LUMI_CREDIT_SCALE;
        assert!(user_amount >= min_lumi_out, E_MAX_INPUT);
        if (user_amount > 0) {
            credit.user_units = credit.user_units - user_amount * LUMI_CREDIT_SCALE;
            let user_lumi = lumi::withdraw_lumi_reserve(lumi_vault, admin, user_amount, ctx);
            transfer::public_transfer(user_lumi, tx_context::sender(ctx));
        };
        if (operations_amount > 0) {
            credit.operations_units = credit.operations_units - operations_amount * LUMI_CREDIT_SCALE;
            let operations_lumi = lumi::withdraw_lumi_reserve(lumi_vault, admin, operations_amount, ctx);
            transfer::public_transfer(operations_lumi, router::operations_wallet(router));
        };
    }

    public fun pending_lumi_credit<CoinTypeA, CoinTypeB>(position: &CetusPosition<CoinTypeA, CoinTypeB>): (u64, u64) {
        if (!dynamic_field::exists_<LumiCreditKey>(&position.id, LumiCreditKey {})) return (0, 0);
        let credit = dynamic_field::borrow<LumiCreditKey, LumiCredit>(&position.id, LumiCreditKey {});
        (credit.user_units, credit.operations_units)
    }

    fun add_lumi_credit<CoinTypeA, CoinTypeB>(position: &mut CetusPosition<CoinTypeA, CoinTypeB>, quoted_lumi_units: u64) {
        let fee_units = router::lumi_claim_fee(quoted_lumi_units);
        let user_units = quoted_lumi_units - fee_units;
        if (!dynamic_field::exists_<LumiCreditKey>(&position.id, LumiCreditKey {})) {
            dynamic_field::add(&mut position.id, LumiCreditKey {}, LumiCredit { user_units, operations_units: fee_units });
        } else {
            let credit = dynamic_field::borrow_mut<LumiCreditKey, LumiCredit>(&mut position.id, LumiCreditKey {});
            credit.user_units = credit.user_units + user_units;
            credit.operations_units = credit.operations_units + fee_units;
        };
    }

    fun borrow_lumi_credit_mut<CoinTypeA, CoinTypeB>(position: &mut CetusPosition<CoinTypeA, CoinTypeB>): &mut LumiCredit {
        if (!dynamic_field::exists_<LumiCreditKey>(&position.id, LumiCreditKey {})) {
            dynamic_field::add(&mut position.id, LumiCreditKey {}, LumiCredit { user_units: 0, operations_units: 0 });
        };
        dynamic_field::borrow_mut<LumiCreditKey, LumiCredit>(&mut position.id, LumiCreditKey {})
    }

    fun split_native_fees<CoinType>(fees: &mut Balance<CoinType>): (Balance<CoinType>, Balance<CoinType>) {
        let amount = balance::value(fees);
        let (operations_fee, protocol_fee) = router::native_reward_fees(amount);
        let operations = balance::split(fees, operations_fee);
        let protocol = balance::split(fees, protocol_fee);
        (operations, protocol)
    }

    fun settle_native_sui_fallback(
        router: &Router, farm_id: u64, mut reward: Balance<SUI>, retained_sui_vault: &mut RevenueVault<SUI>, ctx: &mut TxContext,
    ) {
        let reward_amount = balance::value(&reward);
        let (operations_fee, protocol_fee) = router::native_reward_fees(reward_amount);
        let operations = balance::split(&mut reward, operations_fee);
        let protocol = balance::split(&mut reward, protocol_fee);
        revenue::deposit(retained_sui_vault, protocol);
        transfer::public_transfer(coin::from_balance(reward, ctx), tx_context::sender(ctx));
        if (operations_fee > 0) transfer::public_transfer(coin::from_balance(operations, ctx), router::operations_wallet(router)) else balance::destroy_zero(operations);
        event::emit(NativeRewardClaimed { farm_id, reward_amount, operations_fee, protocol_fee });
    }
}
