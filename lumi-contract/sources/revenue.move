/// Typed protocol-revenue vaults. One shared vault is created for each coin
/// type that a reviewed adapter may route as protocol revenue.
module lumi::revenue {
    use lumi::lumi::AdminCap;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;

    const E_PAUSED: u64 = 1;
    const E_BAD_AMOUNT: u64 = 2;

    public struct RevenueVault<phantom CoinType> has key {
        id: UID,
        balance: Balance<CoinType>,
        paused: bool,
    }

    public entry fun create_vault<CoinType>(_admin: &AdminCap, ctx: &mut TxContext) {
        transfer::share_object(RevenueVault<CoinType> {
            id: object::new(ctx),
            balance: balance::zero<CoinType>(),
            paused: false,
        });
    }

    public fun deposit<CoinType>(vault: &mut RevenueVault<CoinType>, incoming: Balance<CoinType>) {
        assert!(!vault.paused, E_PAUSED);
        balance::join(&mut vault.balance, incoming);
    }

    /// Guarded-launch escape hatch. A later liquidity-deployment adapter will
    /// replace this with a constrained, price-checked deployment path.
    public fun withdraw<CoinType>(
        vault: &mut RevenueVault<CoinType>,
        _admin: &AdminCap,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<CoinType> {
        assert!(!vault.paused, E_PAUSED);
        assert!(amount > 0 && amount <= balance::value(&vault.balance), E_BAD_AMOUNT);
        coin::from_balance(balance::split(&mut vault.balance, amount), ctx)
    }

    public entry fun set_paused<CoinType>(
        vault: &mut RevenueVault<CoinType>,
        _admin: &AdminCap,
        paused: bool,
    ) { vault.paused = paused; }

    public fun value<CoinType>(vault: &RevenueVault<CoinType>): u64 {
        balance::value(&vault.balance)
    }
}
