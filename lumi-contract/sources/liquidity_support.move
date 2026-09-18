/// Protocol-owned LUMI/SUI liquidity support.
///
/// This module never values or guarantees a user's LP principal.  It only
/// deploys protocol SUI revenue beside fixed-reserve LUMI at a guarded market
/// ratio, making the public LUMI/SUI market deeper without making LUMI the
/// counterparty to a user's farm outcome.
module lumi::liquidity_support {
    use cetus_clmm::config::GlobalConfig;
    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::position::Position;
    use lumi::lumi::{Self, AdminCap, LUMI, Vault};
    use lumi::price_oracle::{Self, PriceOracle};
    use lumi::revenue::{Self, RevenueVault};
    use lumi::router::{Self, Router};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::TxContext;

    const E_PAUSED: u64 = 1;
    const E_ORACLE: u64 = 2;
    const E_MINIMUM: u64 = 3;
    const E_ZERO: u64 = 4;

    /// TWAP is the protected reference and spot must already be within 2%.
    /// A further half percent covers integer rounding while keeping the
    /// reserve draw bounded.
    const LUMI_CAP_BPS: u64 = 10_250;
    const BPS_DENOMINATOR: u64 = 10_000;

    /// One protocol-owned Cetus LUMI/SUI position.  It is shared so the next
    /// allocation can add to the same position; it is not a user receipt.
    public struct LumiSuiLiquidityPosition has key {
        id: UID,
        position: Position,
        tick_lower: u32,
        tick_upper: u32,
    }

    public struct LiquiditySupported has copy, drop {
        position_id: sui::object::ID,
        lumi_deployed: u64,
        sui_deployed: u64,
        lumi_returned: u64,
        sui_returned: u64,
    }

    /// Opens the first protocol-owned LUMI/SUI position in one transaction.
    /// `sui_budget` is withdrawn from the SUI revenue vault; the LUMI reserve
    /// draw is calculated from the five-minute TWAP and capped.  Any amount
    /// Cetus does not consume is returned to the same vault it came from.
    public entry fun create_lumi_sui_support(
        router: &Router,
        admin: &AdminCap,
        lumi_vault: &mut Vault,
        sui_revenue_vault: &mut RevenueVault<SUI>,
        oracle: &PriceOracle,
        pool: &mut Pool<LUMI, SUI>,
        config: &GlobalConfig,
        sui_budget: u64,
        tick_lower: u32,
        tick_upper: u32,
        min_lumi_deployed: u64,
        min_sui_deployed: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!router::is_paused(router), E_PAUSED);
        assert!(sui_budget > 0, E_ZERO);
        let mut position = pool::open_position(config, pool, tick_lower, tick_upper, ctx);
        let (lumi_deployed, sui_deployed, lumi_returned, sui_returned) = deploy(
            admin, lumi_vault, sui_revenue_vault, oracle, pool, config, &mut position,
            sui_budget, min_lumi_deployed, min_sui_deployed, clock, ctx,
        );
        let position_id = object::id(&position);
        transfer::share_object(LumiSuiLiquidityPosition {
            id: object::new(ctx), position, tick_lower, tick_upper,
        });
        event::emit(LiquiditySupported {
            position_id, lumi_deployed, sui_deployed, lumi_returned, sui_returned,
        });
    }

    /// Adds a further oracle-matched allocation to an existing protocol
    /// LUMI/SUI position.  Tick changes are deliberately excluded: Cetus
    /// requires a separate remove-and-open rebalance operation for that.
    public entry fun add_lumi_sui_support(
        router: &Router,
        admin: &AdminCap,
        support: &mut LumiSuiLiquidityPosition,
        lumi_vault: &mut Vault,
        sui_revenue_vault: &mut RevenueVault<SUI>,
        oracle: &PriceOracle,
        pool: &mut Pool<LUMI, SUI>,
        config: &GlobalConfig,
        sui_budget: u64,
        min_lumi_deployed: u64,
        min_sui_deployed: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!router::is_paused(router), E_PAUSED);
        assert!(sui_budget > 0, E_ZERO);
        let (lumi_deployed, sui_deployed, lumi_returned, sui_returned) = deploy(
            admin, lumi_vault, sui_revenue_vault, oracle, pool, config, &mut support.position,
            sui_budget, min_lumi_deployed, min_sui_deployed, clock, ctx,
        );
        event::emit(LiquiditySupported {
            position_id: object::id(&support.position), lumi_deployed, sui_deployed,
            lumi_returned, sui_returned,
        });
    }

    fun deploy(
        admin: &AdminCap,
        lumi_vault: &mut Vault,
        sui_revenue_vault: &mut RevenueVault<SUI>,
        oracle: &PriceOracle,
        pool: &mut Pool<LUMI, SUI>,
        config: &GlobalConfig,
        position: &mut Position,
        sui_budget: u64,
        min_lumi_deployed: u64,
        min_sui_deployed: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64, u64, u64) {
        assert!(price_oracle::is_twap_ready(oracle, 300, clock), E_ORACLE);
        let twap = price_oracle::twap_sqrt_price(oracle, 300, clock);
        assert!(price_oracle::is_spot_within_twap_deviation(pool::current_sqrt_price(pool), twap), E_ORACLE);
        let twap_lumi = price_oracle::quote_b_to_a(sui_budget, twap);
        assert!(twap_lumi > 0, E_ZERO);
        let lumi_cap = with_cap(twap_lumi);
        let mut lumi_coin = lumi::withdraw_lumi_for_settlement(lumi_vault, lumi_cap, ctx);
        let mut sui_coin = revenue::withdraw(sui_revenue_vault, admin, sui_budget, ctx);

        // Fix the SUI side.  The capped reserve draw must cover the LUMI
        // amount Cetus asks for at the guarded current spot, or all state
        // changes revert.
        let receipt = pool::add_liquidity_fix_coin(config, pool, position, sui_budget, false, clock);
        let (lumi_needed, sui_needed) = pool::add_liquidity_pay_amount(&receipt);
        assert!(lumi_needed <= coin::value(&lumi_coin) && sui_needed <= coin::value(&sui_coin), E_ORACLE);
        assert!(lumi_needed >= min_lumi_deployed && sui_needed >= min_sui_deployed, E_MINIMUM);
        let lumi_payment = coin::into_balance(coin::split(&mut lumi_coin, lumi_needed, ctx));
        let sui_payment = coin::into_balance(coin::split(&mut sui_coin, sui_needed, ctx));
        pool::repay_add_liquidity(config, pool, lumi_payment, sui_payment, receipt);

        let lumi_returned = coin::value(&lumi_coin);
        let sui_returned = coin::value(&sui_coin);
        lumi::return_lumi_from_liquidity(lumi_vault, lumi_coin);
        revenue::deposit_coin(sui_revenue_vault, sui_coin);
        (lumi_needed, sui_needed, lumi_returned, sui_returned)
    }

    fun with_cap(amount: u64): u64 {
        (amount / BPS_DENOMINATOR) * LUMI_CAP_BPS
            + ((amount % BPS_DENOMINATOR) * LUMI_CAP_BPS) / BPS_DENOMINATOR
    }
}


