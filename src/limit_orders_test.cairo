use core::num::traits::{Zero};
use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher};
use ekubo::interfaces::mathlib::{dispatcher as mathlib, IMathLibDispatcherTrait};
use ekubo::interfaces::positions::{IPositionsDispatcher};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount};
use ekubo::types::call_points::{CallPoints};
use ekubo::types::delta::{Delta};
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use ekubo_limit_orders_extension::limit_orders::{
    OrderKey, GetOrderInfoRequest, GetOrderInfoResult, ILimitOrdersDispatcher,
    ILimitOrdersDispatcherTrait, OrderState, LimitOrders::LIMIT_ORDER_TICK_SPACING
};
use ekubo_limit_orders_extension::limit_orders_test_periphery::{
    ILimitOrdersTestPeripheryDispatcher, ILimitOrdersTestPeripheryDispatcherTrait
};
use ekubo_limit_orders_extension::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{declare, DeclareResultTrait, ContractClassTrait, ContractClass};
use starknet::{get_contract_address, contract_address_const, ContractAddress};

fn deploy_token(
    class: @ContractClass, recipient: ContractAddress, amount: u256
) -> IERC20Dispatcher {
    let (contract_address, _) = class
        .deploy(@array![recipient.into(), amount.low.into(), amount.high.into()])
        .expect('Deploy token failed');

    IERC20Dispatcher { contract_address }
}

fn deploy_limit_orders(core: ICoreDispatcher) -> IExtensionDispatcher {
    let contract = declare("LimitOrders").unwrap().contract_class();
    let (contract_address, _) = contract
        .deploy(@array![get_contract_address().into(), core.contract_address.into()])
        .expect('Deploy failed');

    IExtensionDispatcher { contract_address }
}

fn deploy_limit_orders_test_periphery(
    core: ICoreDispatcher, limit_orders: IExtensionDispatcher
) -> ILimitOrdersTestPeripheryDispatcher {
    let contract = declare("LimitOrdersTestPeriphery").unwrap().contract_class();
    let (contract_address, _) = contract
        .deploy(@array![core.contract_address.into(), limit_orders.contract_address.into()])
        .expect('Deploy failed');

    ILimitOrdersTestPeripheryDispatcher { contract_address }
}

fn ekubo_core() -> ICoreDispatcher {
    ICoreDispatcher {
        contract_address: contract_address_const::<
            0x00000005dd3D2F4429AF886cD1a3b08289DBcEa99A294197E9eB43b0e0325b4b
        >()
    }
}

fn positions() -> IPositionsDispatcher {
    IPositionsDispatcher {
        contract_address: contract_address_const::<
            0x02e0af29598b407c8716b17f6d2795eca1b471413fa03fb145a5e33722184067
        >()
    }
}

fn router() -> IRouterDispatcher {
    IRouterDispatcher {
        contract_address: contract_address_const::<
            0x0199741822c2dc722f6f605204f35e56dbc23bceed54818168c4c49e4fb8737e
        >()
    }
}

fn setup() -> (PoolKey, ILimitOrdersTestPeripheryDispatcher) {
    let limit_orders = deploy_limit_orders(ekubo_core());
    let periphery = deploy_limit_orders_test_periphery(ekubo_core(), limit_orders);
    let token_class = declare("TestToken").unwrap().contract_class();
    let owner = get_contract_address();
    let (tokenA, tokenB) = (
        deploy_token(token_class, owner, 0xffffffffffffffffffffffffffffffff),
        deploy_token(token_class, owner, 0xffffffffffffffffffffffffffffffff)
    );
    let (token0, token1) = if (tokenA.contract_address < tokenB.contract_address) {
        (tokenA, tokenB)
    } else {
        (tokenB, tokenA)
    };

    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: 0,
        tick_spacing: LIMIT_ORDER_TICK_SPACING,
        extension: limit_orders.contract_address,
    };

    (pool_key, periphery)
}

#[test]
#[fork("mainnet")]
fn test_constructor_sets_call_points() {
    let (pool_key, _) = setup();
    assert_eq!(
        ekubo_core().get_call_points(pool_key.extension),
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


#[test]
#[fork("mainnet")]
fn test_pool_is_not_initialized() {
    let (pool_key, _) = setup();
    let pool_price = ekubo_core().get_pool_price(pool_key);

    assert_eq!(pool_price.sqrt_ratio, Zero::zero());
    assert_eq!(pool_price.tick, Zero::zero());
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: "Only from place_order")]
fn test_pool_cannot_be_initialized_manually() {
    let (pool_key, _) = setup();
    ekubo_core().initialize_pool(pool_key, Zero::zero());
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Order already exists',))]
fn test_cannot_place_two_orders_for_same_key() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    sell_token.transfer(periphery.contract_address, 64);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 64);
    periphery.place_order(salt, order_key, liquidity);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Liquidity must be non-zero',))]
fn test_cannot_place_order_for_zero_liquidity() {
    let (pool_key, periphery) = setup();
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 0_u128;
    periphery.place_order(salt, order_key, liquidity);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Zero liquidity',))]
fn test_cannot_close_order_without_liquidity() {
    let (pool_key, periphery) = setup();
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    periphery.close_order(salt, order_key);
}

#[test]
#[fork("mainnet")]
fn test_place_order_and_fully_execute_sell_token0() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    sell_token.transfer(periphery.contract_address, 64);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 64);
    let extension = ILimitOrdersDispatcher { contract_address: pool_key.extension };
    assert_eq!(
        extension
            .get_order_infos(
                array![GetOrderInfoRequest { owner: periphery.contract_address, salt, order_key }]
                    .span()
            ),
        array![
            GetOrderInfoResult {
                state: OrderState { ticks_crossed_at_create: 1, liquidity: 1000000 },
                executed: false,
                amount0: 63,
                amount1: 0
            }
        ]
            .span()
    );
    let pool_price = ekubo_core().get_pool_price(pool_key);
    assert_eq!(pool_price.sqrt_ratio, u256 { low: 0, high: 1 });
    assert_eq!(pool_price.tick, i129 { mag: 0, sign: false });

    let buy_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    buy_token.transfer(router().contract_address, 100);
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 63, sign: true }, amount1: i129 { mag: 65, sign: false } }
    );

    assert_eq!(
        extension
            .get_order_infos(
                array![GetOrderInfoRequest { owner: periphery.contract_address, salt, order_key }]
                    .span()
            ),
        array![
            GetOrderInfoResult {
                state: OrderState { ticks_crossed_at_create: 1, liquidity: 1000000 },
                executed: true,
                amount0: 0,
                amount1: 64,
            }
        ]
            .span()
    );

    assert_eq!(periphery.close_order(salt, order_key), (0, 64));
}


#[test]
#[fork("mainnet")]
fn test_place_order_and_fully_execute_sell_token1() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    sell_token.transfer(periphery.contract_address, 65);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 65);
    let extension = ILimitOrdersDispatcher { contract_address: pool_key.extension };
    assert_eq!(
        extension
            .get_order_infos(
                array![GetOrderInfoRequest { owner: periphery.contract_address, salt, order_key }]
                    .span()
            ),
        array![
            GetOrderInfoResult {
                state: OrderState { ticks_crossed_at_create: 1, liquidity: 1000000 },
                executed: false,
                amount0: 0,
                amount1: 64
            }
        ]
            .span()
    );
    let pool_price = ekubo_core().get_pool_price(pool_key);
    assert_eq!(
        pool_price.sqrt_ratio,
        mathlib().tick_to_sqrt_ratio(i129 { mag: LIMIT_ORDER_TICK_SPACING * 2, sign: false })
    );
    assert_eq!(pool_price.tick, i129 { mag: LIMIT_ORDER_TICK_SPACING * 2, sign: false });

    let buy_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    buy_token.transfer(router().contract_address, 100);
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key, sqrt_ratio_limit: u256 { low: 0, high: 1 }, skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 64, sign: false }, amount1: i129 { mag: 64, sign: true } }
    );

    assert_eq!(
        extension
            .get_order_infos(
                array![GetOrderInfoRequest { owner: periphery.contract_address, salt, order_key }]
                    .span()
            ),
        array![
            GetOrderInfoResult {
                state: OrderState { ticks_crossed_at_create: 1, liquidity: 1000000 },
                executed: true,
                amount0: 63,
                amount1: 0
            }
        ]
            .span()
    );

    assert_eq!(periphery.close_order(salt, order_key), (63, 0));
}


#[test]
#[fork("mainnet")]
fn test_place_order_and_partially_execute_sell_token0() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    sell_token.transfer(periphery.contract_address, 64);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 64);

    let buy_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    buy_token.transfer(router().contract_address, 100);
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(
                            i129 { mag: LIMIT_ORDER_TICK_SPACING / 2, sign: false }
                        ),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 31, sign: true }, amount1: i129 { mag: 33, sign: false } }
    );

    assert_eq!(periphery.close_order(salt, order_key), (31, 32));
}


#[test]
#[fork("mainnet")]
fn test_place_order_and_partially_execute_sell_token1() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    sell_token.transfer(periphery.contract_address, 65);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 65);

    let buy_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    buy_token.transfer(router().contract_address, 100);
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(
                            i129 {
                                mag: LIMIT_ORDER_TICK_SPACING + (LIMIT_ORDER_TICK_SPACING / 2),
                                sign: false
                            }
                        ),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 32, sign: false }, amount1: i129 { mag: 32, sign: true } }
    );

    assert_eq!(periphery.close_order(salt, order_key), (31, 32));
}


#[test]
#[fork("mainnet")]
fn test_place_orders_only_one_executed_sell_token0() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    sell_token.transfer(periphery.contract_address, 64);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 64);

    let buy_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    buy_token.transfer(router().contract_address, 100);
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 63, sign: true }, amount1: i129 { mag: 65, sign: false } }
    );
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib().tick_to_sqrt_ratio(i129 { mag: 0, sign: false }),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: sell_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 0, sign: true }, amount1: i129 { mag: 0, sign: false } }
    );

    // place another order after the first one executed
    sell_token.transfer(periphery.contract_address, 64);
    assert_eq!(periphery.place_order(salt + 1, order_key, liquidity), 64);

    // close the first one
    assert_eq!(periphery.close_order(salt, order_key), (0, 64));
    // close the second one
    assert_eq!(periphery.close_order(salt + 1, order_key), (63, 0));
}

#[test]
#[fork("mainnet")]
fn test_place_orders_only_one_executed_sell_token1() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    sell_token.transfer(periphery.contract_address, 65);
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 65);

    let buy_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    buy_token.transfer(router().contract_address, 100);
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: buy_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 64, sign: false }, amount1: i129 { mag: 64, sign: true } }
    );
    assert_eq!(
        router()
            .swap(
                node: RouteNode {
                    pool_key,
                    sqrt_ratio_limit: mathlib()
                        .tick_to_sqrt_ratio(
                            i129 { mag: LIMIT_ORDER_TICK_SPACING * 2, sign: false }
                        ),
                    skip_ahead: 0
                },
                token_amount: TokenAmount {
                    token: sell_token.contract_address, amount: i129 { mag: 100, sign: false }
                }
            ),
        Delta { amount0: i129 { mag: 0, sign: true }, amount1: i129 { mag: 0, sign: false } }
    );

    // place another order after the first one executed
    sell_token.transfer(periphery.contract_address, 65);
    assert_eq!(periphery.place_order(salt + 1, order_key, liquidity), 65);

    // close the first one
    assert_eq!(periphery.close_order(salt, order_key), (63, 0));
    // close the second one
    assert_eq!(periphery.close_order(salt + 1, order_key), (0, 64));
}
