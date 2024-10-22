use core::traits::{Into, TryInto};
use ekubo::types::i129::{i129, i129Trait};
use starknet::{ContractAddress, storage_access::{StorePacking}};

#[derive(Drop, Copy, Serde, Hash, PartialEq, Debug)]
pub struct OrderKey {
    // The first token sorted by address
    pub token0: ContractAddress,
    // The second token sorted by address
    pub token1: ContractAddress,
    // The price at which the token should be bought/sold. Must be a multiple of tick spacing.
    // If the specified tick is evenly divisible by 2 * tick_spacing, it implies that the order is
    // selling token1.
    pub tick: i129,
}

// State of a particular order, stored separately per (owner, salt, order key)
#[derive(Drop, Copy, Serde, PartialEq, Debug)]
pub(crate) struct OrderState {
    // The total number of initialized ticks that the pool has crossed when this order was created
    pub ticks_crossed_at_create: u64,
    // How much liquidity was deposited for this order
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
pub(crate) struct PoolState {
    // The number of times this pool has crossed an initialized tick plus one
    pub ticks_crossed: u64,
    // The last tick that was seen for the pool
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

#[derive(Drop, Copy, Serde, PartialEq, Debug)]
pub struct GetOrderInfoRequest {
    pub owner: ContractAddress,
    pub salt: felt252,
    pub order_key: OrderKey,
}

#[derive(Drop, Copy, Serde, PartialEq, Debug)]
pub struct GetOrderInfoResult {
    pub(crate) state: OrderState,
    pub executed: bool,
    pub amount0: u128,
    pub amount1: u128,
}

// Pass through to `Core#forward` to creates a new limit order, selling the given `sell_token` for
// the given `buy_token` at the specified tick.
#[derive(Drop, Copy, Serde)]
pub struct PlaceOrderForwardCallbackData {
    pub salt: felt252,
    pub order_key: OrderKey,
    pub liquidity: u128,
}

// Pass through to `Core#forward` to closes an order with the given token ID, returning the amount
// of token0 and token1 to the recipient
#[derive(Drop, Copy, Serde)]
pub struct CloseOrderForwardCallbackData {
    pub salt: felt252,
    pub order_key: OrderKey,
}

// Pass to `Core#forward` to interact with limit orders
#[derive(Drop, Copy, Serde)]
pub enum ForwardCallbackData {
    PlaceOrder: PlaceOrderForwardCallbackData,
    CloseOrder: CloseOrderForwardCallbackData,
}

#[derive(Drop, Copy, Serde)]
pub enum ForwardCallbackResult {
    // Returns the amount that must be paid to cover the order
    PlaceOrder: u128,
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
    use starknet::{get_contract_address};
    use super::{
        ILimitOrders, i129, ContractAddress, OrderKey, OrderState, PoolState, GetOrderInfoRequest,
        GetOrderInfoResult, ForwardCallbackData, PlaceOrderForwardCallbackData,
        CloseOrderForwardCallbackData, ForwardCallbackResult
    };

    pub const LIMIT_ORDER_TICK_SPACING: u128 = 128;
    pub const DOUBLE_LIMIT_ORDER_TICK_SPACING: u128 = 256;

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
        pools: Map<(ContractAddress, ContractAddress), PoolState>,
        ticks_crossed_last_crossing: Map<(ContractAddress, ContractAddress), Map<i129, u64>>,
        orders: Map<(ContractAddress, felt252, OrderKey), OrderState>,
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
            // the limit order extension can create pools using this extension.
            panic!("Only from place_order");
        }

        fn after_initialize_pool(
            ref self: ContractState, caller: ContractAddress, pool_key: PoolKey, initial_tick: i129
        ) {
            panic!("Not used");
        }

        fn before_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters
        ) {
            panic!("Not used");
        }

        fn after_swap(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: SwapParameters,
            delta: Delta
        ) {
            let core = self.core.read();

            call_core_with_callback::<(PoolKey, u128), ()>(core, @(pool_key, params.skip_ahead));
        }

        fn before_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters
        ) {
            // pools with this extension may only contain limit orders, to simplify routing
            panic!("Only limit orders");
        }

        fn after_update_position(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            params: UpdatePositionParameters,
            delta: Delta
        ) {
            panic!("Not used");
        }

        fn before_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds
        ) {
            panic!("Not used");
        }
        fn after_collect_fees(
            ref self: ContractState,
            caller: ContractAddress,
            pool_key: PoolKey,
            salt: felt252,
            bounds: Bounds,
            delta: Delta
        ) {
            panic!("Not used");
        }
    }

    impl OrderKeyIntoPoolKey of Into<OrderKey, PoolKey> {
        fn into(self: OrderKey) -> PoolKey {
            PoolKey {
                token0: self.token0,
                token1: self.token1,
                fee: 0,
                tick_spacing: LIMIT_ORDER_TICK_SPACING,
                extension: get_contract_address()
            }
        }
    }

    #[abi(embed_v0)]
    impl LockedImpl of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            let (pool_key, skip_ahead) = consume_callback_data::<(PoolKey, u128)>(core, data);

            let tick_after_swap = core.get_pool_price(pool_key).tick;
            let state_entry = self.pools.entry((pool_key.token0, pool_key.token1));
            let state = state_entry.read();
            let mut ticks_crossed = state.ticks_crossed;

            let pool_ticks_crossed_entry = self
                .ticks_crossed_last_crossing
                .entry((pool_key.token0, pool_key.token1));

            if (tick_after_swap != state.last_tick) {
                let this_address = get_contract_address();
                let price_increasing = tick_after_swap > state.last_tick;
                let mut tick_current = state.last_tick;
                let mut save_amount: u128 = 0;

                loop {
                    let (next_tick, is_initialized) = if price_increasing {
                        core.next_initialized_tick(pool_key, tick_current, skip_ahead)
                    } else {
                        core.prev_initialized_tick(pool_key, tick_current, skip_ahead)
                    };

                    if ((next_tick > tick_after_swap) == price_increasing) {
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
                                pool_key, PositionKey { salt: 0, owner: this_address, bounds }
                            );

                        let delta = core
                            .update_position(
                                pool_key,
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
                        pool_ticks_crossed_entry.write(next_tick, ticks_crossed);
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
                                owner: this_address,
                                token: if price_increasing {
                                    pool_key.token1
                                } else {
                                    pool_key.token0
                                },
                                salt: 0,
                            },
                            save_amount
                        );
                }

                state_entry.write(PoolState { ticks_crossed, last_tick: tick_after_swap });
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
                    let PlaceOrderForwardCallbackData { salt, order_key, liquidity } = place_order;

                    assert(liquidity > 0, 'Liquidity must be non-zero');

                    let is_selling_token1 = (order_key.tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                        .is_non_zero();

                    let core = self.core.read();

                    let pool_key: PoolKey = order_key.into();

                    let state_entry = self.pools.entry((order_key.token0, order_key.token1));
                    let order_entry = self.orders.entry((original_locker, salt, order_key));

                    assert(order_entry.read().liquidity.is_zero(), 'Order already exists');

                    let mut pool_state = state_entry.read();

                    // the ticks crossed is zero IFF the pool is not initialized
                    if (pool_state.ticks_crossed.is_zero()) {
                        let initial_tick = if is_selling_token1 {
                            order_key.tick + i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                        } else {
                            order_key.tick
                        };

                        pool_state = PoolState { ticks_crossed: 1, last_tick: initial_tick };

                        state_entry.write(pool_state);
                        core.initialize_pool(order_key.into(), initial_tick);
                    }

                    order_entry
                        .write(
                            OrderState {
                                ticks_crossed_at_create: pool_state.ticks_crossed, liquidity
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

                    if is_selling_token1 {
                        assert(delta.amount0.is_zero(), 'TICK_WRONG_SIDE');
                        ForwardCallbackResult::PlaceOrder(delta.amount1.mag)
                    } else {
                        assert(delta.amount1.is_zero(), 'TICK_WRONG_SIDE');
                        ForwardCallbackResult::PlaceOrder(delta.amount0.mag)
                    }
                },
                ForwardCallbackData::CloseOrder(close_order) => {
                    let CloseOrderForwardCallbackData { salt, order_key } = close_order;

                    let order = self.orders.read((original_locker, salt, order_key));
                    assert(order.liquidity.is_non_zero(), 'Zero liquidity');

                    self
                        .orders
                        .write(
                            (original_locker, salt, order_key),
                            OrderState { liquidity: 0, ticks_crossed_at_create: 0 }
                        );

                    let pool_key: PoolKey = order_key.into();

                    let core = self.core.read();

                    let is_selling_token1 = (order_key.tick.mag % DOUBLE_LIMIT_ORDER_TICK_SPACING)
                        .is_non_zero();

                    let ticks_crossed_at_order_tick = self
                        .ticks_crossed_last_crossing
                        .entry((order_key.token0, order_key.token1))
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
                let price = core.get_pool_price((*request.order_key).into());

                assert(price.sqrt_ratio.is_non_zero(), 'INVALID_ORDER_KEY');

                let ticks_crossed_at_order_tick = self
                    .ticks_crossed_last_crossing
                    .entry((*request.order_key.token0, *request.order_key.token1))
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
