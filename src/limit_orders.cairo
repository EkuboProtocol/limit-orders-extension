mod math;

use core::traits::{Into, TryInto};
use ekubo::types::i129::{i129, i129Trait};
use starknet::{ContractAddress, ClassHash, storage_access::{StorePacking}};

#[derive(Drop, Copy, Serde, Hash)]
pub struct OrderKey {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub tick: i129,
}

// State of a particular order, defined by the key
#[derive(Drop, Copy, Serde, PartialEq)]
pub struct OrderState {
    // the number of ticks crossed when this order was created
    pub ticks_crossed_at_create: u64,
    // how much liquidity was deposited for this order
    pub liquidity: u128,
}

impl OrderStateStorePacking of StorePacking<OrderState, felt252> {
    fn pack(value: OrderState) -> felt252 {
        u256 { low: value.liquidity, high: value.ticks_crossed_at_create.into() }
            .try_into()
            .unwrap()
    }
    fn unpack(value: felt252) -> OrderState {
        let x: u256 = value.into();

        OrderState { ticks_crossed_at_create: x.high.try_into().unwrap(), liquidity: x.low }
    }
}

// The state of the pool as it was last seen
#[derive(Drop, Copy, Serde, PartialEq)]
pub struct PoolState {
    // the number of initialized ticks that have been crossed, minus 1
    pub ticks_crossed: u64,
    // the last tick that was seen for the pool
    pub last_tick: i129,
}

impl PoolStateStorePacking of StorePacking<PoolState, felt252> {
    fn pack(value: PoolState) -> felt252 {
        u256 {
            low: value.last_tick.mag,
            high: if value.last_tick.is_negative() {
                value.ticks_crossed.into() + 0x10000000000000000
            } else {
                value.ticks_crossed.into()
            }
        }
            .try_into()
            .unwrap()
    }
    fn unpack(value: felt252) -> PoolState {
        let x: u256 = value.into();

        if (x.high >= 0x10000000000000000) {
            PoolState {
                last_tick: i129 { mag: x.low, sign: true },
                ticks_crossed: (x.high - 0x10000000000000000).try_into().unwrap()
            }
        } else {
            PoolState {
                last_tick: i129 { mag: x.low, sign: false },
                ticks_crossed: x.high.try_into().unwrap()
            }
        }
    }
}

#[derive(Drop, Copy, Serde)]
pub struct GetOrderInfoRequest {
    pub owner: ContractAddress,
    pub salt: felt252,
    pub order_key: OrderKey,
}

#[derive(Drop, Copy, Serde)]
pub struct GetOrderInfoResult {
    pub state: OrderState,
    pub executed: bool,
    pub amount0: u128,
    pub amount1: u128,
}

#[starknet::interface]
pub trait ILimitOrders<TContractState> {
    // Return information on each of the given orders
    fn get_order_infos(
        self: @TContractState, requests: Span<GetOrderInfoRequest>
    ) -> Span<GetOrderInfoResult>;

    // Creates a new limit order, selling the given `sell_token` for the given `buy_token` at the specified tick
    // The size of the new order is determined by the current balance of the sell token
    fn place_order(ref self: TContractState, salt: felt252, order_key: OrderKey, amount: u128);

    // Closes an order with the given token ID, returning the amount of token0 and token1 to the recipient
    fn close_order(
        ref self: TContractState, salt: felt252, order_key: OrderKey, recipient: ContractAddress
    ) -> (u128, u128);
}

mod components {
    use starknet::{ContractAddress};

    #[starknet::interface]
    pub trait IOwned<TContractState> {
        // Returns the current owner of the contract
        fn get_owner(self: @TContractState) -> ContractAddress;
        // Transfers the ownership to a new address
        fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);
    }

    pub trait Ownable<TContractState> {
        // Initialize the owner of the contract
        fn initialize_owned(ref self: TContractState, owner: ContractAddress);

        // Any ownable contract can require that the owner is calling a particular method
        fn require_owner(self: @TContractState) -> ContractAddress;
    }

    #[starknet::component]
    pub mod Owned {
        use core::num::traits::{Zero};
        use starknet::{get_caller_address, contract_address_const};
        use super::{ContractAddress, IOwned, Ownable};

        #[storage]
        struct Storage {
            owner: ContractAddress,
        }

        #[derive(starknet::Event, Drop)]
        pub struct OwnershipTransferred {
            pub old_owner: ContractAddress,
            pub new_owner: ContractAddress,
        }

        #[event]
        #[derive(Drop, starknet::Event)]
        pub enum Event {
            OwnershipTransferred: OwnershipTransferred
        }


        pub impl OwnableImpl<
            TContractState, +Drop<TContractState>, +HasComponent<TContractState>
        > of Ownable<TContractState> {
            fn initialize_owned(ref self: TContractState, owner: ContractAddress) {
                let mut component = self.get_component_mut();
                let old_owner = component.owner.read();
                component.owner.write(owner);
                component.emit(OwnershipTransferred { old_owner, new_owner: owner });
            }

            fn require_owner(self: @TContractState) -> ContractAddress {
                let owner = self.get_component().get_owner();
                assert(get_caller_address() == owner, 'OWNER_ONLY');
                return owner;
            }
        }

        #[embeddable_as(OwnedImpl)]
        pub impl Owned<
            TContractState, +Drop<TContractState>, +HasComponent<TContractState>
        > of IOwned<ComponentState<TContractState>> {
            fn get_owner(self: @ComponentState<TContractState>) -> ContractAddress {
                self.owner.read()
            }

            fn transfer_ownership(
                ref self: ComponentState<TContractState>, new_owner: ContractAddress
            ) {
                let old_owner = self.get_contract().require_owner();
                self.owner.write(new_owner);
                self.emit(OwnershipTransferred { old_owner, new_owner });
            }
        }
    }
}

#[starknet::contract]
pub mod LimitOrders {
    use core::array::{ArrayTrait};
    use core::num::traits::{Zero};
    use core::option::{OptionTrait};
    use core::traits::{TryInto, Into};
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
    use ekubo::components::upgradeable::{
        Upgradeable as upgradeable_component, IHasInterface, IUpgradeable, IUpgradeableDispatcher,
        IUpgradeableDispatcherTrait
    };
    use ekubo::interfaces::core::{
        IExtension, SwapParameters, UpdatePositionParameters, ILocker, ICoreDispatcher,
        ICoreDispatcherTrait
    };
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::delta::{Delta};
    use ekubo::types::keys::{PoolKey, PositionKey};
    use ekubo::types::keys::{SavedBalanceKey};
    use starknet::{get_contract_address, get_caller_address, ClassHash};
    use super::math::delta::{amount0_delta, amount1_delta};
    use super::math::liquidity::{liquidity_delta_to_amount_delta};
    use super::math::max_liquidity::{max_liquidity_for_token0, max_liquidity_for_token1};
    use super::math::ticks::{tick_to_sqrt_ratio};
    use super::{
        ILimitOrders, i129, i129Trait, ContractAddress, OrderKey, OrderState, PoolState,
        GetOrderInfoRequest, GetOrderInfoResult
    };

    pub const LIMIT_ORDER_TICK_SPACING: u128 = 100;
    pub const DOUBLE_LIMIT_ORDER_TICK_SPACING: u128 = 200;

    #[abi(embed_v0)]
    impl Clear = ekubo::components::clear::ClearImpl<ContractState>;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Upgradeable = upgradeable_component::UpgradeableImpl<ContractState>;

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        pools: LegacyMap<PoolKey, PoolState>,
        orders: LegacyMap<(ContractAddress, felt252, OrderKey), OrderState>,
        ticks_crossed_last_crossing: LegacyMap<(PoolKey, i129), u64>,
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, core: ICoreDispatcher) {
        self.initialize_owned(owner);
        self.core.write(core);
        core
            .set_call_points(
                CallPoints {
                    before_initialize_pool: true,
                    after_initialize_pool: false,
                    before_swap: false,
                    after_swap: true,
                    before_update_position: true,
                    after_update_position: false,
                    before_collect_fees: false,
                    after_collect_fees: false,
                }
            );
    }


    #[derive(Serde, Copy, Drop)]
    struct PlaceOrderCallbackData {
        pool_key: PoolKey,
        is_selling_token1: bool,
        tick: i129,
        liquidity: u128,
    }

    #[derive(Serde, Copy, Drop)]
    struct HandleAfterSwapCallbackData {
        pool_key: PoolKey,
        skip_ahead: u128,
    }

    #[derive(Serde, Copy, Drop)]
    struct WithdrawExecutedOrderBalance {
        token: ContractAddress,
        amount: u128,
        recipient: ContractAddress,
    }

    #[derive(Serde, Copy, Drop)]
    struct WithdrawUnexecutedOrderBalance {
        pool_key: PoolKey,
        tick: i129,
        liquidity: u128,
        recipient: ContractAddress,
    }

    #[derive(Serde, Copy, Drop)]
    enum LockCallbackData {
        PlaceOrderCallbackData: PlaceOrderCallbackData,
        HandleAfterSwapCallbackData: HandleAfterSwapCallbackData,
        WithdrawExecutedOrderBalance: WithdrawExecutedOrderBalance,
        WithdrawUnexecutedOrderBalance: WithdrawUnexecutedOrderBalance,
    }

    #[derive(Serde, Copy, Drop)]
    enum LockCallbackResult {
        Empty: (),
        Delta: Delta,
    }

    #[derive(starknet::Event, Drop)]
    struct OrderPlaced {
        owner: ContractAddress,
        salt: felt252,
        order_key: OrderKey,
        amount: u128,
        liquidity: u128,
    }

    #[derive(starknet::Event, Drop)]
    struct OrderClosed {
        owner: ContractAddress,
        salt: felt252,
        amount0: u128,
        amount1: u128,
    }


    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        #[flat]
        UpgradeableEvent: upgradeable_component::Event,
        OwnedEvent: owned_component::Event,
        OrderPlaced: OrderPlaced,
        OrderClosed: OrderClosed,
    }

    #[abi(embed_v0)]
    impl LimitOrdersHasInterface of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            return selector!("ekubo::extensions::limit_orders::LimitOrders");
        }
    }

    #[abi(embed_v0)]
    impl ExtensionImpl of IExtension<ContractState> {
        fn before_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            // this entrypoint is not called if the limit order extension initializes the pool
            panic!("ONLY_FROM_PLACE_ORDER");
        }

        fn after_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            panic!("NOT_USED");
        }

        fn before_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters
        ) {
            panic!("NOT_USED");
        }


        fn after_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters,
            delta: Delta
        ) {
            let core = self.core.read();

            call_core_with_callback::<
                LockCallbackData, ()
            >(
                core,
                @LockCallbackData::HandleAfterSwapCallbackData(
                    HandleAfterSwapCallbackData { pool_key, skip_ahead: params.skip_ahead }
                )
            );
        }

        fn before_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters
        ) {
            // only this contract can create positions, and the extension will not be called in that case, so always revert
            panic!("ONLY_LIMIT_ORDERS");
        }


        fn after_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
            delta: Delta
        ) {
            panic!("NOT_USED");
        }

        fn before_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds
        ) {
            panic!("NOT_USED");
        }
        fn after_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds,
            delta: Delta
        ) {
            panic!("NOT_USED");
        }
    }

    #[abi(embed_v0)]
    impl LockerImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            let result: LockCallbackResult =
                match consume_callback_data::<LockCallbackData>(core, data) {
                LockCallbackData::PlaceOrderCallbackData(place_order) => {
                    let delta = core
                        .update_position(
                            pool_key: place_order.pool_key,
                            params: UpdatePositionParameters {
                                // all the positions have the same salt
                                salt: 0,
                                bounds: Bounds {
                                    lower: place_order.tick,
                                    upper: place_order.tick
                                        + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false },
                                },
                                liquidity_delta: i129 { mag: place_order.liquidity, sign: false }
                            }
                        );

                    let (pay_token, pay_amount, other_is_zero) = if place_order.is_selling_token1 {
                        (place_order.pool_key.token1, delta.amount1.mag, delta.amount0.is_zero())
                    } else {
                        (place_order.pool_key.token0, delta.amount0.mag, delta.amount1.is_zero())
                    };

                    assert(other_is_zero, 'TICK_WRONG_SIDE');

                    IERC20Dispatcher { contract_address: pay_token }
                        .approve(core.contract_address, pay_amount.into());
                    core.pay(pay_token);

                    LockCallbackResult::Empty
                },
                LockCallbackData::HandleAfterSwapCallbackData(after_swap) => {
                    let price_after_swap = core.get_pool_price(after_swap.pool_key);
                    let state = self.pools.read(after_swap.pool_key);
                    let mut ticks_crossed = state.ticks_crossed;

                    if (price_after_swap.tick != state.last_tick) {
                        let price_increasing = price_after_swap.tick > state.last_tick;
                        let mut tick_current = state.last_tick;
                        let mut save_amount: u128 = 0;

                        loop {
                            let (next_tick, is_initialized) = if price_increasing {
                                core
                                    .next_initialized_tick(
                                        after_swap.pool_key, tick_current, after_swap.skip_ahead
                                    )
                            } else {
                                core
                                    .prev_initialized_tick(
                                        after_swap.pool_key, tick_current, after_swap.skip_ahead
                                    )
                            };

                            if ((next_tick > price_after_swap.tick) == price_increasing) {
                                break ();
                            };

                            if (is_initialized
                                & ((next_tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                                    .is_non_zero())) {
                                let bounds = if price_increasing {
                                    Bounds {
                                        lower: next_tick
                                            - i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false },
                                        upper: next_tick,
                                    }
                                } else {
                                    Bounds {
                                        lower: next_tick,
                                        upper: next_tick
                                            + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false },
                                    }
                                };

                                let position_data = core
                                    .get_position(
                                        after_swap.pool_key,
                                        PositionKey {
                                            salt: 0, owner: get_contract_address(), bounds
                                        }
                                    );

                                let delta = core
                                    .update_position(
                                        after_swap.pool_key,
                                        UpdatePositionParameters {
                                            salt: 0,
                                            bounds,
                                            liquidity_delta: i129 {
                                                mag: position_data.liquidity, sign: true
                                            }
                                        }
                                    );

                                save_amount +=
                                    if price_increasing {
                                        delta.amount1.mag
                                    } else {
                                        delta.amount0.mag
                                    };
                                ticks_crossed += 1;
                                self
                                    .ticks_crossed_last_crossing
                                    .write((after_swap.pool_key, next_tick), ticks_crossed);
                            };

                            tick_current =
                                if price_increasing {
                                    next_tick
                                } else {
                                    next_tick - i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                                };
                        };

                        if (save_amount.is_non_zero()) {
                            core
                                .save(
                                    SavedBalanceKey {
                                        owner: get_contract_address(),
                                        token: if price_increasing {
                                            after_swap.pool_key.token1
                                        } else {
                                            after_swap.pool_key.token0
                                        },
                                        salt: 0,
                                    },
                                    save_amount
                                );
                        }

                        self
                            .pools
                            .write(
                                after_swap.pool_key,
                                PoolState { ticks_crossed, last_tick: price_after_swap.tick }
                            );
                    }

                    LockCallbackResult::Empty
                },
                LockCallbackData::WithdrawExecutedOrderBalance(withdraw) => {
                    core.load(token: withdraw.token, salt: 0, amount: withdraw.amount);
                    core
                        .withdraw(
                            token_address: withdraw.token,
                            recipient: withdraw.recipient,
                            amount: withdraw.amount
                        );
                    LockCallbackResult::Empty
                },
                LockCallbackData::WithdrawUnexecutedOrderBalance(withdraw) => {
                    let delta = core
                        .update_position(
                            pool_key: withdraw.pool_key,
                            params: UpdatePositionParameters {
                                // all the positions have the same salt
                                salt: 0,
                                bounds: Bounds {
                                    lower: withdraw.tick,
                                    upper: withdraw.tick
                                        + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false },
                                },
                                liquidity_delta: i129 { mag: withdraw.liquidity, sign: true }
                            }
                        );

                    if (delta.amount0.is_non_zero()) {
                        core
                            .withdraw(
                                token_address: withdraw.pool_key.token0,
                                recipient: withdraw.recipient,
                                amount: delta.amount0.mag
                            );
                    }

                    if (delta.amount1.is_non_zero()) {
                        core
                            .withdraw(
                                token_address: withdraw.pool_key.token1,
                                recipient: withdraw.recipient,
                                amount: delta.amount1.mag
                            );
                    }

                    LockCallbackResult::Delta(delta)
                }
            };

            let mut result_data = array![];
            Serde::serialize(@result, ref result_data);
            result_data.span()
        }
    }

    fn to_pool_key(order_key: OrderKey) -> PoolKey {
        PoolKey {
            token0: order_key.token0,
            token1: order_key.token1,
            fee: 0,
            tick_spacing: LIMIT_ORDER_TICK_SPACING,
            extension: get_contract_address()
        }
    }

    #[abi(embed_v0)]
    impl LimitOrderImpl of ILimitOrders<ContractState> {
        fn place_order(ref self: ContractState, salt: felt252, order_key: OrderKey, amount: u128) {
            let pool_key = to_pool_key(order_key);
            let is_selling_token1 = (order_key.tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                .is_non_zero();

            let core = self.core.read();

            // check the price is on the right side of the order tick
            {
                let price = core.get_pool_price(pool_key);

                // the first order initializes the pool just next to where the order is placed
                if (price.sqrt_ratio.is_zero()) {
                    let initial_tick = if is_selling_token1 {
                        order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                    } else {
                        order_key.tick
                    };

                    self
                        .pools
                        .write(pool_key, PoolState { ticks_crossed: 1, last_tick: initial_tick });
                    core.initialize_pool(pool_key, initial_tick);
                }
            }

            let sqrt_ratio_lower = tick_to_sqrt_ratio(order_key.tick);
            let sqrt_ratio_upper = tick_to_sqrt_ratio(
                order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
            );
            let liquidity = if is_selling_token1 {
                max_liquidity_for_token1(sqrt_ratio_lower, sqrt_ratio_upper, amount)
            } else {
                max_liquidity_for_token0(sqrt_ratio_lower, sqrt_ratio_upper, amount)
            };

            assert(liquidity > 0, 'SELL_AMOUNT_TOO_SMALL');

            let owner = get_caller_address();
            self
                .orders
                .write(
                    (owner, salt, order_key),
                    OrderState {
                        ticks_crossed_at_create: self.pools.read(pool_key).ticks_crossed, liquidity
                    }
                );

            call_core_with_callback::<
                LockCallbackData, ()
            >(
                core,
                @LockCallbackData::PlaceOrderCallbackData(
                    PlaceOrderCallbackData {
                        pool_key, tick: order_key.tick, is_selling_token1, liquidity
                    }
                )
            );

            self.emit(OrderPlaced { owner, salt, order_key, amount, liquidity });
        }

        fn close_order(
            ref self: ContractState, salt: felt252, order_key: OrderKey, recipient: ContractAddress
        ) -> (u128, u128) {
            let owner = get_caller_address();
            let order = self.orders.read((owner, salt, order_key));
            assert(order.liquidity.is_non_zero(), 'INVALID_ORDER_KEY');

            self
                .orders
                .write(
                    (owner, salt, order_key),
                    OrderState { liquidity: 0, ticks_crossed_at_create: 0 }
                );

            let pool_key = to_pool_key(order_key);

            let core = self.core.read();

            let is_selling_token1 = (order_key.tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                .is_non_zero();

            let ticks_crossed_at_order_tick = self
                .ticks_crossed_last_crossing
                .read(
                    (
                        pool_key,
                        if is_selling_token1 {
                            order_key.tick
                        } else {
                            order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                        }
                    )
                );

            // the order is fully executed, just withdraw the saved balance
            let (amount0, amount1) = if (ticks_crossed_at_order_tick > order
                .ticks_crossed_at_create) {
                let sqrt_ratio_a = tick_to_sqrt_ratio(order_key.tick);
                let sqrt_ratio_b = tick_to_sqrt_ratio(
                    order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                );

                let (amount0, amount1) = if is_selling_token1 {
                    (
                        amount0_delta(
                            sqrt_ratio_a, sqrt_ratio_b, liquidity: order.liquidity, round_up: false
                        ),
                        0_u128
                    )
                } else {
                    (
                        0_u128,
                        amount1_delta(
                            sqrt_ratio_a, sqrt_ratio_b, liquidity: order.liquidity, round_up: false
                        )
                    )
                };

                call_core_with_callback::<
                    LockCallbackData, ()
                >(
                    core,
                    @LockCallbackData::WithdrawExecutedOrderBalance(
                        if is_selling_token1 {
                            WithdrawExecutedOrderBalance {
                                token: order_key.token0, amount: amount0, recipient,
                            }
                        } else {
                            WithdrawExecutedOrderBalance {
                                token: order_key.token1, amount: amount1, recipient,
                            }
                        }
                    )
                );

                (amount0, amount1)
            } else {
                match call_core_with_callback::<
                    LockCallbackData, LockCallbackResult
                >(
                    core,
                    @LockCallbackData::WithdrawUnexecutedOrderBalance(
                        WithdrawUnexecutedOrderBalance {
                            pool_key, tick: order_key.tick, liquidity: order.liquidity, recipient
                        }
                    )
                ) {
                    LockCallbackResult::Empty => {
                        assert(false, 'EMPTY_RESULT');
                        (0, 0)
                    },
                    LockCallbackResult::Delta(delta) => { (delta.amount0.mag, delta.amount1.mag) }
                }
            };

            self.emit(OrderClosed { owner, salt, amount0, amount1 });

            (amount0, amount1)
        }

        fn get_order_infos(
            self: @ContractState, mut requests: Span<GetOrderInfoRequest>
        ) -> Span<GetOrderInfoResult> {
            let mut result: Array<GetOrderInfoResult> = array![];

            let core = self.core.read();

            while let Option::Some(request) = requests
                .pop_front() {
                    let is_selling_token1 = (*request
                        .order_key
                        .tick
                        .mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                        .is_non_zero();
                    let pool_key = to_pool_key(*request.order_key);
                    let price = core.get_pool_price(pool_key);

                    assert(price.sqrt_ratio.is_non_zero(), 'INVALID_ORDER_KEY');

                    let ticks_crossed_at_order_tick = self
                        .ticks_crossed_last_crossing
                        .read(
                            (
                                pool_key,
                                if is_selling_token1 {
                                    *request.order_key.tick
                                } else {
                                    *request.order_key.tick
                                        + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                                }
                            )
                        );

                    let order = self
                        .orders
                        .read((*request.owner, *request.salt, *request.order_key));

                    // the order is fully executed, just withdraw the saved balance
                    if (ticks_crossed_at_order_tick > order.ticks_crossed_at_create) {
                        let sqrt_ratio_a = tick_to_sqrt_ratio(request.order_key.tick);
                        let sqrt_ratio_b = tick_to_sqrt_ratio(
                            request.order_key.tick
                                + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                        );

                        let (amount0, amount1) = if is_selling_token1 {
                            (
                                amount0_delta(
                                    sqrt_ratio_a,
                                    sqrt_ratio_b,
                                    liquidity: order.liquidity,
                                    round_up: false
                                ),
                                0
                            )
                        } else {
                            (
                                0,
                                amount1_delta(
                                    sqrt_ratio_a,
                                    sqrt_ratio_b,
                                    liquidity: order.liquidity,
                                    round_up: false
                                )
                            )
                        };

                        result
                            .append(
                                GetOrderInfoResult {
                                    state: order, executed: true, amount0, amount1
                                }
                            );
                    } else {
                        let delta = liquidity_delta_to_amount_delta(
                            sqrt_ratio: price.sqrt_ratio,
                            liquidity_delta: i129 { mag: order.liquidity, sign: true },
                            sqrt_ratio_lower: tick_to_sqrt_ratio(request.order_key.tick),
                            sqrt_ratio_upper: tick_to_sqrt_ratio(
                                request.order_key.tick
                                    + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                            )
                        );

                        result
                            .append(
                                GetOrderInfoResult {
                                    state: order,
                                    executed: false,
                                    amount0: delta.amount0.mag,
                                    amount1: delta.amount1.mag
                                }
                            );
                    }
                };

            result.span()
        }
    }
}
