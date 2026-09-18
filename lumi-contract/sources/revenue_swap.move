/// Admin-gated, exact-input Cetus conversions from a typed protocol-revenue
/// vault into the SUI revenue vault.  The caller supplies a hard minimum SUI
/// receipt and a Cetus square-root price boundary; an unsuccessful quote
/// aborts atomically, leaving every vault unchanged.
module lumi::revenue_swap {
    use cetus_clmm::config::GlobalConfig;
    use cetus_clmm::pool::{Self, Pool};
    use lumi::lumi::AdminCap;
    use lumi::revenue::{Self, RevenueVault};
    use sui::balance;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::sui::SUI;
    use sui::tx_context::TxContext;

    const E_ZERO: u64 = 1;
    const E_MINIMUM: u64 = 2;
    const E_PARTIAL: u64 = 3;

    public struct RevenueSwappedToSui has copy, drop {
        input_amount: u64,
        sui_out: u64,
    }

    /// Swap exactly `amount_in` of the pool's A coin for SUI.  This module is
    /// deliberately limited to A-to-SUI pools; every other route needs its
    /// own reviewed adapter rather than a generic arbitrary-call escape hatch.
    public entry fun swap_vault_a_to_sui<CoinTypeA>(
        admin: &AdminCap,
        input_vault: &mut RevenueVault<CoinTypeA>,
        sui_vault: &mut RevenueVault<SUI>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, SUI>,
        amount_in: u64,
        min_sui_out: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(amount_in > 0, E_ZERO);
        let mut input = revenue::withdraw(input_vault, admin, amount_in, ctx);
        let (returned_a, received_sui, receipt) = pool::flash_swap<CoinTypeA, SUI>(
            config, pool, true, true, amount_in, sqrt_price_limit, clock,
        );
        let paid = pool::swap_pay_amount(&receipt);
        // A price boundary must never turn this into a partial vault sale.
        assert!(paid == amount_in, E_PARTIAL);
        let sui_out = balance::value(&received_sui);
        assert!(sui_out >= min_sui_out, E_MINIMUM);

        let payment = coin::into_balance(coin::split(&mut input, paid, ctx));
        pool::repay_flash_swap(
            config, pool, payment, balance::zero<SUI>(), receipt,
        );
        // No A output is expected for an A-to-B exact-input swap, but joining
        // it makes the accounting total and safely returns it to its vault.
        coin::join(&mut input, coin::from_balance(returned_a, ctx));
        revenue::deposit_coin(input_vault, input);
        revenue::deposit(sui_vault, received_sui);
        event::emit(RevenueSwappedToSui { input_amount: amount_in, sui_out });
    }
}
