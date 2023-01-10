module suins::auction {

    use sui::object::UID;
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::transfer;
    use sui::object;
    use std::option::{Self, Option};
    use sui::coin::Coin;
    use suins::coin_util;
    use sui::event;
    use std::string::{String, utf8};
    use std::vector;
    use std::bcs;
    use sui::ecdsa_k1::keccak256;
    // use suins::base_registrar::BaseRegistrar;
    // use suins::base_registry::Registry;
    // use suins::configuration::Configuration;
    // use suins::base_registrar;
    // // use suins::base_registrar::BaseRegistrar;
    // use suins::base_registry::Registry;
    // use suins::configuration::Configuration;
    // use suins::base_registrar;

    const MIN_PRICE: u64 = 1000;
    const BIDDING_PERIOD: u64 = 3;
    const REVEAL_PERIOD: u64 = 3;
    const AUCTION_STATE_NOT_AVAILABLE: u8 = 0;
    const AUCTION_STATE_OPEN: u8 = 1;
    const AUCTION_STATE_BIDDING: u8 = 2;
    const AUCTION_STATE_REVEAL: u8 = 3;
    const AUCTION_STATE_OWNED: u8 = 4;

    const EUnauthorized: u64 = 801;
    const EInvalidPhase: u64 = 802;
    const EAuctionNotAvailable: u64 = 803;
    const EBidExisted: u64 = 804;
    const EInvalidBid: u64 = 805;
    const EBidAlreadyStart: u64 = 806;
    const EInvalidBidMask: u64 = 807;
    const EInvalidBidValue: u64 = 807;

    struct BidDetail has store, drop {
        bidder: address,
        // upper limit of the actual bid value to hide the real value
        bid_value_mask: u64,
        created_at: u64,
    }

    // info of each auction this is ongoing or over
    struct AuctionEntry has store {
        start_at: u64,
        highest_bid: u64,
        second_highest_bid: u64,
        winner: address,
    }

    struct Auction has key {
        id: UID,
        // key: seal hash
        seal_bids: Table<vector<u8>, BidDetail>,
        // key: node
        entries: Table<String, AuctionEntry>,
        balance: Balance<SUI>,
        auction_launch_start_at: u64,
        auction_launch_end_at: u64,
    }

    struct NodeRegisteredEvent has copy, drop {
        node: String,
        winner: address,
        amount: u64,
    }

    struct NewBidEvent has copy, drop {
        bidder: address,
        seal_bid: vector<u8>,
        bid_value_mask: u64,
    }

    struct BidRevealedEvent has copy, drop {
        node: String,
        bidder: address,
        bid_value: u64,
    }

    struct AuctionStartedEvent has copy, drop {
        node: String,
        start_at: u64,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(Auction {
            id: object::new(ctx),
            seal_bids: table::new(ctx),
            entries: table::new(ctx),
            balance: balance::zero(),
            auction_launch_start_at: 0,
            auction_launch_end_at: 0,
        });
    }

    public entry fun new_bid(auction: &mut Auction, seal_bid: vector<u8>, bid_value_mask: u64, payment: &mut Coin<SUI>, ctx: &mut TxContext) {
        let current_epoch = tx_context::epoch(ctx);
        assert!(
            auction.auction_launch_start_at <= current_epoch && current_epoch <= auction.auction_launch_end_at,
            EAuctionNotAvailable,
        );
        assert!(!table::contains(&auction.seal_bids, seal_bid), EBidExisted);
        assert!(bid_value_mask >= MIN_PRICE, EInvalidBid);
        let bidder = tx_context::sender(ctx);
        let bid = BidDetail {
            bidder,
            bid_value_mask,
            created_at: current_epoch,
        };
        table::add(&mut auction.seal_bids, seal_bid, bid);
        event::emit(NewBidEvent { bidder, seal_bid, bid_value_mask });
        coin_util::user_transfer_to_contract(payment, bid_value_mask, &mut auction.balance);
    }

    // // Cancels an unrevealed bid
    // public entry fun cancel_bid(auction: &mut Auction, seal_bid: vector<u8>, ctx: &mut TxContext) {
    //     // TODO:
    // }

    // public entry fun finalize_auction(
    //     auction: &mut Auction,
    //     registrar: &mut BaseRegistrar,
    //     registry: &mut Registry,
    //     config: &Configuration,
    //     node: vector<u8>,
    //     ctx: &mut TxContext
    // ) {
    //     // TODO: check registrar base_node
    //     let node_str = utf8(node);
    //     let entry = table::borrow_mut(&mut auction.entries, node_str);
    //     assert!(entry.winner == tx_context::sender(ctx), EUnauthorized);
    //     let state = state(entry);
    //     assert!(state == AUCTION_STATE_OWNED, EInvalidPhase);
    //     // TODO: where to find default_resolver_address
    //     base_registrar::register(registrar, registry, config, node, entry.winner, 1, @0x0, ctx);
    //     event::emit(NodeRegisteredEvent {
    //         node: node_str,
    //         winner: entry.winner,
    //         amount: entry.second_highest_bid
    //     })
    // }

    public entry fun unseal_bid(auction: &mut Auction, node: vector<u8>, value: u64, salt: vector<u8>, ctx: &mut TxContext) {
        let seal_bid = make_seal_bid(node, tx_context::sender(ctx), value, salt); // hash from node, owner, value, salt
        // TODO: validate domain name
        let node = utf8(node);
        let auction_state = state(auction, node, ctx);
        assert!(auction_state != AUCTION_STATE_BIDDING, EInvalidPhase);
        let entry = table::borrow_mut(&mut auction.entries, *&node);
        let bid_detail = table::remove(&mut auction.seal_bids, seal_bid); // get and remove the bid
        // TODO: remove later
        assert!(!table::contains(&auction.seal_bids, seal_bid), 10);
        assert!(bid_detail.bidder == tx_context::sender(ctx), EUnauthorized);

        if (
            bid_detail.bid_value_mask < value
                || bid_detail.created_at < entry.start_at || entry.start_at + BIDDING_PERIOD < bid_detail.created_at
                || value < MIN_PRICE
        ) {
            // invalid bid
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask, bid_detail.bidder, ctx);
        } else if (tx_context::epoch(ctx) > entry.start_at + BIDDING_PERIOD + REVEAL_PERIOD) {
            // reveal too late, apply a harsh punishment to avoid extortion attack
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask, bid_detail.bidder, ctx);
        } else if (auction_state == AUCTION_STATE_OWNED) {
            // Too late! Bidder loses their bid. Get's his/her money back
            // TODO: contract charges a small amount as a punishment
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask, bid_detail.bidder, ctx);
        } else if (auction_state == AUCTION_STATE_OPEN || auction_state == AUCTION_STATE_NOT_AVAILABLE) {
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask, bid_detail.bidder, ctx);
        } else if (value > entry.highest_bid) {
            // in REVEAL phase
            // new winner, refund previous highest paid
            if (entry.winner != @0x0)
                coin_util::contract_transfer_to_address(&mut auction.balance, entry.highest_bid, entry.winner, ctx);
            // send back extra money to sender
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask - value, bid_detail.bidder, ctx);
            // vickery auction, previous highest_bid is value to be paid by winner
            entry.second_highest_bid = entry.highest_bid;
            entry.highest_bid = value;
            entry.winner = bid_detail.bidder;
        } else if (value > entry.second_highest_bid) {
            // not winner, but affects second place
            entry.second_highest_bid = value;
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask, bid_detail.bidder, ctx);
        } else {
            // bid doesn't affect auction
            coin_util::contract_transfer_to_address(&mut auction.balance, bid_detail.bid_value_mask, bid_detail.bidder, ctx);
        };
        event::emit(BidRevealedEvent {
            node,
            bidder: bid_detail.bidder,
            bid_value: value,
        })
    }

    // State transitions for names:
    // Open -> Bidding (startAuction) -> Reveal -> Owned
    fun state(auction: &Auction, node: String, ctx: &mut TxContext): u8 {
        let current_epoch = tx_context::epoch(ctx);
        if (current_epoch < auction.auction_launch_start_at || current_epoch > auction.auction_launch_end_at) return AUCTION_STATE_NOT_AVAILABLE;
        if (table::contains(&auction.entries, node)) {
            let entry = table::borrow(&auction.entries, node);
            if (current_epoch < entry.start_at + BIDDING_PERIOD) return AUCTION_STATE_BIDDING;
            if (current_epoch < entry.start_at + BIDDING_PERIOD + REVEAL_PERIOD) return AUCTION_STATE_REVEAL;
            // TODO: what if noone bid on this domain?
            // TODO: check for highest_bid != 0
            return AUCTION_STATE_OWNED
        };
        AUCTION_STATE_OPEN
    }

    // TODO: should we hash node?
    public entry fun start_auction(auction: &mut Auction, node: vector<u8>, ctx: &mut TxContext) {
        let node = utf8(node);
        let state = state(auction, node, ctx);
        assert!(state == AUCTION_STATE_OPEN, EInvalidPhase);
        // current_epoch was validated in `state`
        let start_at = tx_context::epoch(ctx) + 1;
        let entry = AuctionEntry {
            start_at,
            highest_bid: 0,
            second_highest_bid: 0,
            winner: @0x0,
        };
        table::add(&mut auction.entries, node, entry);
        event::emit(AuctionStartedEvent { node, start_at })
    }

    public fun make_seal_bid(node: vector<u8>, owner: address, value: u64, salt: vector<u8>): vector<u8> {
        let owner = bcs::to_bytes(&owner);
        vector::append(&mut node, owner);
        let value = bcs::to_bytes(&value);
        vector::append(&mut node, value);
        vector::append(&mut node, salt);
        keccak256(&node)
    }

    public fun get_entry(auction: &Auction, node: vector<u8>): (Option<u64>, Option<u64>, Option<u64>, Option<address>) {
        let node = utf8(node);
        if (table::contains(&auction.entries, node)) {
            let entry = table::borrow(&auction.entries, node);
            return (
                option::some(entry.start_at),
                option::some(entry.highest_bid),
                option::some(entry.second_highest_bid),
                option::some(entry.winner)
            )
        };
        (option::none(), option::none(), option::none(), option::none())
    }

    public fun get_bid(auction: &Auction, seal_bid: vector<u8>): (Option<address>, Option<u64>) {
        if (table::contains(&auction.seal_bids, seal_bid)) {
            let bid = table::borrow(&auction.seal_bids, seal_bid);
            return (option::some(bid.bidder), option::some(bid.bid_value_mask))
        };
        (option::none(), option::none())
    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        transfer::share_object(Auction {
            id: object::new(ctx),
            seal_bids: table::new(ctx),
            entries: table::new(ctx),
            balance: balance::zero(),
            auction_launch_start_at: 100,
            auction_launch_end_at: 200,
        });
    }
}
