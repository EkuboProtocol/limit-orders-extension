use core::traits::{Into, TryInto};
use ekubo::types::i129::{i129, i129Trait};
use starknet::{ContractAddress, storage_access::{StorePacking}};

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

// Pass through to `Core#forward` to creates a new limit order, selling the given `sell_token` for
// the given `buy_token` at the specified tick.
#[derive(Drop, Copy, Serde)]
pub struct PlaceOrderForwardCallbackData {
    salt: felt252,
    order_key: OrderKey,
    amount: u128,
}

// Pass through to `Core#forward` to closes an order with the given token ID, returning the amount
// of token0 and token1 to the recipient
#[derive(Drop, Copy, Serde)]
pub struct CloseOrderForwardCallbackData {
    salt: felt252,
    order_key: OrderKey,
}

// Pass to `Core#forward` to interact with limit orders
#[derive(Drop, Copy, Serde)]
pub enum ForwardCallbackData {
    PlaceOrder: PlaceOrderForwardCallbackData,
    CloseOrder: CloseOrderForwardCallbackData,
}

#[derive(Drop, Copy, Serde)]
pub enum ForwardCallbackResult {
    PlaceOrder: (),
    // The amount of token0 and token1 received for closing the order
    CloseOrder: (u128, u128)
}

#[starknet::interface]
pub trait ILimitOrders<TContractState> {
    // Return information on each of the given orders
    fn get_order_infos(
        self: @TContractState, requests: Span<GetOrderInfoRequest>
    ) -> Span<GetOrderInfoResult>;
}

#[starknet::contract]
pub mod LimitOrders {
    use core::array::{ArrayTrait};
    use core::num::traits::{Zero};
    use core::traits::{Into};
    use ekubo::components::clear::{ClearImpl};
    use ekubo::components::owned::{Owned as owned_component};
    use ekubo::components::shared_locker::{call_core_with_callback, consume_callback_data};
    use ekubo::components::upgradeable::{Upgradeable as upgradeable_component, IHasInterface};
    use ekubo::interfaces::core::{
        IExtension, SwapParameters, UpdatePositionParameters, IForwardee, ICoreDispatcher,
        ICoreDispatcherTrait, ILocker
    };
    use ekubo::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use ekubo::interfaces::mathlib::{IMathLibDispatcherTrait, dispatcher as mathlib};
    use ekubo::types::bounds::{Bounds};
    use ekubo::types::call_points::{CallPoints};
    use ekubo::types::delta::{Delta};
    use ekubo::types::keys::{PoolKey, PositionKey};
    use ekubo::types::keys::{SavedBalanceKey};
    use starknet::storage::{
        StoragePointerWriteAccess, StorageMapWriteAccess, StorageMapReadAccess,
        StoragePointerReadAccess, StoragePathEntry, Map
    };
    use starknet::{get_contract_address, get_caller_address};
    use super::{
        ILimitOrders, i129, ContractAddress, OrderKey, OrderState, PoolState, GetOrderInfoRequest,
        GetOrderInfoResult, ForwardCallbackData, PlaceOrderForwardCallbackData,
        CloseOrderForwardCallbackData, ForwardCallbackResult
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
        pools: Map<PoolKey, PoolState>,
        orders: Map<(ContractAddress, felt252, OrderKey), OrderState>,
        ticks_crossed_last_crossing: Map<PoolKey, Map<i129, u64>>,
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, core: ICoreDispatcher,) {
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
    struct HandleAfterSwapCallbackData {
        pool_key: PoolKey,
        skip_ahead: u128,
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
            // This entrypoint is not called if the limit order extension initializes the pool. Only
            // the limit order extension can create pools.
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
                HandleAfterSwapCallbackData, ()
            >(core, @HandleAfterSwapCallbackData { pool_key, skip_ahead: params.skip_ahead });
        }

        fn before_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters
        ) {
            // Only this contract can create positions on limit order pools, and the extension will
            // not be called in that case, so always revert
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
    impl LockedImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();

            let after_swap = consume_callback_data::<HandleAfterSwapCallbackData>(core, data);
            let price_after_swap = core.get_pool_price(after_swap.pool_key);
            let state = self.pools.read(after_swap.pool_key);
            let mut ticks_crossed = state.ticks_crossed;

            let pool_crossed_entry = self.ticks_crossed_last_crossing.entry(after_swap.pool_key);

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
                        & ((next_tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING).is_non_zero())) {
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
                                PositionKey { salt: 0, owner: get_contract_address(), bounds }
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
                        pool_crossed_entry.write(next_tick, ticks_crossed);
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

            array![].span()
        }
    }

    #[abi(embed_v0)]
    impl ForwardeeImpl of IForwardee<ContractState> {
        fn forwarded(
            ref self: ContractState, original_locker: ContractAddress, id: u32, data: Span<felt252>
        ) -> Span<felt252> {
            let core = self.core.read();

            let result: ForwardCallbackResult =
                match consume_callback_data::<ForwardCallbackData>(core, data) {
                ForwardCallbackData::PlaceOrder(place_order) => {
                    let PlaceOrderForwardCallbackData { salt, order_key, amount } = place_order;

                    let pool_key = to_pool_key(order_key);
                    let is_selling_token1 = (order_key.tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                        .is_non_zero();

                    let core = self.core.read();

                    // check the price is on the right side of the order tick
                    {
                        let price = core.get_pool_price(pool_key);

                        // the first order initializes the pool just next to where the order is
                        // placed
                        if (price.sqrt_ratio.is_zero()) {
                            let initial_tick = if is_selling_token1 {
                                order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                            } else {
                                order_key.tick
                            };

                            self
                                .pools
                                .write(
                                    pool_key,
                                    PoolState { ticks_crossed: 1, last_tick: initial_tick }
                                );
                            core.initialize_pool(pool_key, initial_tick);
                        }
                    }

                    let math = mathlib();

                    let sqrt_ratio_lower = math.tick_to_sqrt_ratio(order_key.tick);
                    let sqrt_ratio_upper = math
                        .tick_to_sqrt_ratio(
                            order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                        );
                    let liquidity = if is_selling_token1 {
                        math.max_liquidity_for_token1(sqrt_ratio_lower, sqrt_ratio_upper, amount)
                    } else {
                        math.max_liquidity_for_token0(sqrt_ratio_lower, sqrt_ratio_upper, amount)
                    };

                    assert(liquidity > 0, 'SELL_AMOUNT_TOO_SMALL');

                    let owner = get_caller_address();
                    self
                        .orders
                        .write(
                            (owner, salt, order_key),
                            OrderState {
                                ticks_crossed_at_create: self.pools.read(pool_key).ticks_crossed,
                                liquidity
                            }
                        );

                    let delta = core
                        .update_position(
                            pool_key: pool_key,
                            params: UpdatePositionParameters {
                                // all the positions have the same salt
                                salt: 0,
                                bounds: Bounds {
                                    lower: order_key.tick,
                                    upper: order_key.tick
                                        + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false },
                                },
                                liquidity_delta: i129 { mag: liquidity, sign: false }
                            }
                        );

                    let (pay_token, pay_amount, other_is_zero) = if is_selling_token1 {
                        (pool_key.token1, delta.amount1.mag, delta.amount0.is_zero())
                    } else {
                        (pool_key.token0, delta.amount0.mag, delta.amount1.is_zero())
                    };

                    assert(other_is_zero, 'TICK_WRONG_SIDE');

                    IERC20Dispatcher { contract_address: pay_token }
                        .approve(core.contract_address, pay_amount.into());
                    core.pay(pay_token);

                    ForwardCallbackResult::PlaceOrder(())
                },
                ForwardCallbackData::CloseOrder(close_order) => {
                    let CloseOrderForwardCallbackData { salt, order_key } = close_order;

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
                        .entry(pool_key)
                        .read(
                            if is_selling_token1 {
                                order_key.tick
                            } else {
                                order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                            }
                        );

                    // the order is fully executed, just withdraw the saved balance
                    let (amount0, amount1) = if (ticks_crossed_at_order_tick > order
                        .ticks_crossed_at_create) {
                        let math = mathlib();
                        let sqrt_ratio_a = math.tick_to_sqrt_ratio(order_key.tick);
                        let sqrt_ratio_b = math
                            .tick_to_sqrt_ratio(
                                order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                            );

                        let (amount0, amount1) = if is_selling_token1 {
                            (
                                math
                                    .amount0_delta(
                                        sqrt_ratio_a,
                                        sqrt_ratio_b,
                                        liquidity: order.liquidity,
                                        round_up: false
                                    ),
                                0_u128
                            )
                        } else {
                            (
                                0_u128,
                                math
                                    .amount1_delta(
                                        sqrt_ratio_a,
                                        sqrt_ratio_b,
                                        liquidity: order.liquidity,
                                        round_up: false
                                    )
                            )
                        };

                        if amount0.is_non_zero() {
                            core.load(token: order_key.token0, salt: 0, amount: amount0);
                        } else if amount1.is_non_zero() {
                            core.load(token: order_key.token1, salt: 0, amount: amount1);
                        }

                        (amount0, amount1)
                    } else {
                        let delta = core
                            .update_position(
                                pool_key: pool_key,
                                params: UpdatePositionParameters {
                                    // all the positions have the same salt
                                    salt: 0,
                                    bounds: Bounds {
                                        lower: order_key.tick,
                                        upper: order_key.tick
                                            + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false },
                                    },
                                    liquidity_delta: i129 { mag: order.liquidity, sign: true }
                                }
                            );

                        (delta.amount0.mag, delta.amount1.mag)
                    };

                    ForwardCallbackResult::CloseOrder((amount0, amount1))
                }
            };

            let mut result_data = array![];
            Serde::serialize(@result, ref result_data);
            result_data.span()
        }
    }

    #[abi(embed_v0)]
    impl LimitOrderImpl of ILimitOrders<ContractState> {
        fn get_order_infos(
            self: @ContractState, mut requests: Span<GetOrderInfoRequest>
        ) -> Span<GetOrderInfoResult> {
            let mut result: Array<GetOrderInfoResult> = array![];

            let core = self.core.read();

            let math = mathlib();

            while let Option::Some(request) = requests.pop_front() {
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
                    .entry(pool_key)
                    .read(
                        if is_selling_token1 {
                            *request.order_key.tick
                        } else {
                            *request.order_key.tick
                                + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                        }
                    );

                let order = self.orders.read((*request.owner, *request.salt, *request.order_key));

                // the order is fully executed, just withdraw the saved balance
                if (ticks_crossed_at_order_tick > order.ticks_crossed_at_create) {
                    let sqrt_ratio_a = math.tick_to_sqrt_ratio(*request.order_key.tick);
                    let sqrt_ratio_b = math
                        .tick_to_sqrt_ratio(
                            *request.order_key.tick
                                + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                        );

                    let (amount0, amount1) = if is_selling_token1 {
                        (
                            math
                                .amount0_delta(
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
                            math
                                .amount1_delta(
                                    sqrt_ratio_a,
                                    sqrt_ratio_b,
                                    liquidity: order.liquidity,
                                    round_up: false
                                )
                        )
                    };

                    result
                        .append(
                            GetOrderInfoResult { state: order, executed: true, amount0, amount1 }
                        );
                } else {
                    let delta = math
                        .liquidity_delta_to_amount_delta(
                            sqrt_ratio: price.sqrt_ratio,
                            liquidity_delta: i129 { mag: order.liquidity, sign: true },
                            sqrt_ratio_lower: math.tick_to_sqrt_ratio(*request.order_key.tick),
                            sqrt_ratio_upper: math
                                .tick_to_sqrt_ratio(
                                    *request.order_key.tick
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
