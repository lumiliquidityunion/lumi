/// LUMI fixed-supply genesis coin and contract-owned settlement vault.
///
/// V1 mints exactly 100,000,000.00 LUMI (two decimals), transfers the
/// 12,400,000.00 launch allocation to the deployer/temporary operations
/// wallet, and locks the rest in the shared protocol vault.
module lumi::lumi {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url;

    const E_PAUSED: u64 = 1;
    const E_BAD_AMOUNT: u64 = 2;

    const DECIMALS: u8 = 2;
    const TOTAL_SUPPLY: u64 = 10_000_000_000;
    const OPS_ALLOCATION: u64 = 1_240_000_000;

    /// Phantom witness for the fixed-supply LUMI coin.
    public struct LUMI has drop {}

    /// Held by the temporary operations wallet until governance is upgraded.
    public struct AdminCap has key, store { id: UID }

    /// Contract-owned LUMI inventory for later reward and settlement flows.
    /// LUMI's TreasuryCap is locked to the zero address after genesis, so
    /// this vault cannot create additional LUMI.
    public struct Vault has key {
        id: UID,
        lumi_reserve: Balance<LUMI>,
        operations_wallet: address,
        paused: bool,
    }

    public struct GenesisCreated has copy, drop {
        total_supply: u64,
        operations_allocation: u64,
        vault_allocation: u64,
        operations_wallet: address,
    }

    public struct VaultPaused has copy, drop { paused: bool }

    fun init(witness: LUMI, ctx: &mut TxContext) {
        let operations_wallet = tx_context::sender(ctx);
        let (mut treasury_cap, metadata) = coin::create_currency<LUMI>(
            witness,
            DECIMALS,
            b"LUMI",
            b"Liquidity Union",
            b"Curated liquidity-farm access on Sui",
            option::some(url::new_unsafe_from_bytes(b"https://lumiliquidityunion.github.io/lumi/lumi-logo.jpg")),
            ctx,
        );
        let mut issued = coin::mint(&mut treasury_cap, TOTAL_SUPPLY, ctx);
        let operations_coins = coin::split(&mut issued, OPS_ALLOCATION, ctx);
        let vault_allocation = coin::value(&issued);

        transfer::public_transfer(metadata, operations_wallet);
        transfer::public_transfer(operations_coins, operations_wallet);
        transfer::public_transfer(AdminCap { id: object::new(ctx) }, operations_wallet);
        // No account can sign for the zero address. This permanently removes
        // the mint capability while retaining the fixed vault inventory.
        transfer::public_transfer(treasury_cap, @0x0);
        transfer::share_object(Vault {
            id: object::new(ctx),
            lumi_reserve: coin::into_balance(issued),
            operations_wallet,
            paused: false,
        });
        event::emit(GenesisCreated {
            total_supply: TOTAL_SUPPLY,
            operations_allocation: OPS_ALLOCATION,
            vault_allocation,
            operations_wallet,
        });
    }

    public fun total_supply(): u64 { TOTAL_SUPPLY }
    public fun decimals(): u8 { DECIMALS }
    public fun operations_allocation(): u64 { OPS_ALLOCATION }
    public fun vault_balance(vault: &Vault): u64 { balance::value(&vault.lumi_reserve) }
    public fun is_paused(vault: &Vault): bool { vault.paused }
    public fun operations_wallet(vault: &Vault): address { vault.operations_wallet }

    /// Reserved for the protocol's later reward-settlement module. This is
    /// admin-controlled only while the protocol is in its guarded launch
    /// phase; no arbitrary user minting is possible.
    public fun withdraw_lumi_reserve(
        vault: &mut Vault,
        _admin: &AdminCap,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<LUMI> {
        assert!(!vault.paused, E_PAUSED);
        assert!(amount > 0 && amount <= balance::value(&vault.lumi_reserve), E_BAD_AMOUNT);
        coin::from_balance(balance::split(&mut vault.lumi_reserve, amount), ctx)
    }

    public fun set_paused(vault: &mut Vault, _admin: &AdminCap, paused: bool) {
        vault.paused = paused;
        event::emit(VaultPaused { paused });
    }
}
