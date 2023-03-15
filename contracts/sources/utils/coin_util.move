module suins::coin_util {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::tx_context::TxContext;
    use sui::transfer;
    use suins::entity::{Self, SuiNS};

    friend suins::auction;
    friend suins::controller;

    public(friend) fun user_transfer_to_address(
        user_payment: &mut Coin<SUI>,
        amount: u64,
        receiver: address,
        ctx: &mut TxContext
    ) {
        if (amount == 0) return;
        let paid = coin::split(user_payment, amount, ctx);
        transfer::transfer(paid, receiver);
    }

    public(friend) fun user_transfer_to_suins(user_payment: &mut Coin<SUI>, amount: u64, suins: &mut SuiNS) {
        if (amount == 0) return;
        let coin_balance = coin::balance_mut(user_payment);
        let paid = balance::split(coin_balance, amount);
        balance::join(entity::controller_balance_mut(suins), paid);
    }

    public(friend) fun user_transfer_to_auction(user_payment: &mut Coin<SUI>, amount: u64, auction: &mut Balance<SUI>) {
        if (amount == 0) return;
        let coin_balance = coin::balance_mut(user_payment);
        let paid = balance::split(coin_balance, amount);
        balance::join(auction, paid);
    }

    public(friend) fun suins_transfer_to_address(
        suins: &mut SuiNS,
        amount: u64,
        user_addr: address,
        ctx: &mut TxContext
    ) {
        if (amount == 0) return;
        let coin = coin::take(entity::controller_balance_mut(suins), amount, ctx);
        transfer::transfer(coin, user_addr);
    }

    public(friend) fun auction_transfer_to_address(
        auction: &mut Balance<SUI>,
        amount: u64,
        user_addr: address,
        ctx: &mut TxContext
    ) {
        if (amount == 0) return;
        let coin = coin::take(auction, amount, ctx);
        transfer::transfer(coin, user_addr);
    }

    public(friend) fun auction_transfer_to_suins(
        auction: &mut Balance<SUI>,
        amount: u64,
        suins: &mut SuiNS,
    ) {
        if (amount == 0) return;
        let paid = balance::split(auction, amount);
        balance::join(entity::controller_balance_mut(suins), paid);
    }
}
