/// Permissionless observation oracle for the deployed LUMI/SUI pool.
///
/// It records the pool's on-chain square-root price, never a caller-supplied
/// quote. A later conversion adapter will compare a settlement quote to this
/// matured window and the user's minimum output before any swap is executed.
module lumi::price_oracle {
    use cetus_clmm::pool::{Self, Pool};
    use lumi::lumi::LUMI;
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use std::vector;

    const E_TOO_SOON: u64 = 1;
    const E_NOT_READY: u64 = 2;
    const E_BAD_WINDOW: u64 = 3;
    const E_STALE_WINDOW: u64 = 4;
    const SAMPLE_INTERVAL_SECONDS: u64 = 60;
    const MAX_SAMPLE_GAP_SECONDS: u64 = 120;
    const MAX_SAMPLES: u64 = 60;

    public struct Observation has copy, drop, store {
        timestamp: u64,
        sqrt_price: u128,
    }

    public struct PriceOracle has key {
        id: UID,
        observations: vector<Observation>,
    }

    public struct ObservationRecorded has copy, drop {
        timestamp: u64,
        sqrt_price: u128,
        samples: u64,
    }

    public entry fun create(ctx: &mut TxContext) {
        transfer::share_object(PriceOracle { id: object::new(ctx), observations: vector[] });
    }

    /// Anyone may record; the observed value is read directly from the shared
    /// LUMI/SUI pool. One-minute spacing prevents a single PTB from creating a
    /// fake time window.
    public entry fun record_lumi_sui(
        oracle: &mut PriceOracle,
        pool: &Pool<LUMI, sui::sui::SUI>,
        clock: &Clock,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        let count = vector::length(&oracle.observations);
        if (count > 0) {
            let previous = vector::borrow(&oracle.observations, count - 1);
            assert!(timestamp >= previous.timestamp + SAMPLE_INTERVAL_SECONDS, E_TOO_SOON);
        };
        let sqrt_price = pool::current_sqrt_price(pool);
        vector::push_back(&mut oracle.observations, Observation { timestamp, sqrt_price });
        if (vector::length(&oracle.observations) > MAX_SAMPLES) {
            vector::remove(&mut oracle.observations, 0);
        };
        event::emit(ObservationRecorded { timestamp, sqrt_price, samples: vector::length(&oracle.observations) });
    }

    /// Time-weighted mean of the stored sqrt-price observations. It rejects a
    /// window unless samples cover its entire duration with no gap over two
    /// minutes. This is deliberately a guard value, not an execution quote.
    /// Conversion will additionally use a user-specified min-out and a maximum
    /// deviation policy.
    public fun twap_sqrt_price(oracle: &PriceOracle, window_seconds: u64, clock: &Clock): u128 {
        assert!(window_seconds > 0, E_BAD_WINDOW);
        let now = clock::timestamp_ms(clock) / 1000;
        let earliest = if (now > window_seconds) now - window_seconds else 0;
        let count = vector::length(&oracle.observations);
        assert!(count >= 2, E_NOT_READY);
        let first = vector::borrow(&oracle.observations, 0);
        assert!(first.timestamp <= earliest, E_NOT_READY);
        let last = vector::borrow(&oracle.observations, count - 1);
        assert!(last.timestamp + MAX_SAMPLE_GAP_SECONDS >= now, E_STALE_WINDOW);

        let mut weighted: u256 = 0;
        let mut covered: u64 = 0;
        let mut previous = *first;
        let mut i = 1;
        while (i < count) {
            let current = *vector::borrow(&oracle.observations, i);
            let interval_start = if (previous.timestamp > earliest) previous.timestamp else earliest;
            let interval_end = if (current.timestamp < now) current.timestamp else now;
            assert!(current.timestamp <= previous.timestamp + MAX_SAMPLE_GAP_SECONDS, E_STALE_WINDOW);
            if (interval_end > interval_start) {
                let duration = interval_end - interval_start;
                weighted = weighted + (previous.sqrt_price as u256) * (duration as u256);
                covered = covered + duration;
            };
            previous = current;
            i = i + 1;
        };
        if (now > previous.timestamp) {
            let duration = now - previous.timestamp;
            assert!(duration <= MAX_SAMPLE_GAP_SECONDS, E_STALE_WINDOW);
            weighted = weighted + (previous.sqrt_price as u256) * (duration as u256);
            covered = covered + duration;
        };
        assert!(covered == window_seconds, E_NOT_READY);
        (weighted / (covered as u256)) as u128
    }

    public fun sample_count(oracle: &PriceOracle): u64 { vector::length(&oracle.observations) }
}
