use ekubo::interfaces::positions::IPositionsDispatcherTrait;
use core::num::traits::{Zero};
use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher};
use ekubo::interfaces::mathlib::{dispatcher as mathlib, IMathLibDispatcherTrait};
use ekubo::interfaces::positions::{IPositionsDispatcher};
use ekubo::interfaces::router::{IRouterDispatcher, IRouterDispatcherTrait, RouteNode, TokenAmount}; 
use ekubo::types::bounds::{Bounds};
use ekubo::types::call_points::{CallPoints};
use ekubo::types::delta::{Delta}; 
use ekubo::types::i129::{i129};
use ekubo::types::keys::{PoolKey};
use ekubo_limit_orders_extension::limit_orders::{
    OrderKey, GetOrderInfoRequest, GetOrderInfoResult, ILimitOrdersDispatcher,
    ILimitOrdersDispatcherTrait, OrderState, LimitOrders::LIMIT_ORDER_TICK_SPACING, PoolState
};
use ekubo_limit_orders_extension::limit_orders_test_periphery::{
    ILimitOrdersTestPeripheryDispatcher, ILimitOrdersTestPeripheryDispatcherTrait
};
use ekubo_limit_orders_extension::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{declare, DeclareResultTrait, ContractClassTrait, ContractClass, load, map_entry_address};
use starknet::{get_contract_address, contract_address_const, ContractAddress, storage_access::StorePacking};

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

    tokenA.approve(periphery.contract_address, 0xffffffffffffffffffffffffffffffff);
    tokenB.approve(periphery.contract_address, 0xffffffffffffffffffffffffffffffff);

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
#[should_panic(expected: ('Pool not initialized',))]
fn test_cannot_close_order_for_non_existent_pool() {
    let (pool_key, periphery) = setup();
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    periphery.close_order(salt, order_key);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Order does not exist',))]
fn test_cannot_close_order_twice() {
    let (pool_key, periphery) = setup();
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 64);
    periphery.close_order(salt, order_key);
    periphery.close_order(salt, order_key);
}

#[test]
#[fork("mainnet")]
fn test_place_order_and_fully_execute_sell_token0() {
    let (pool_key, periphery) = setup();
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
                state: OrderState { initialized_ticks_crossed_snapshot: 1, liquidity: 1000000 },
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
                state: OrderState { initialized_ticks_crossed_snapshot: 1, liquidity: 1000000 },
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
                state: OrderState { initialized_ticks_crossed_snapshot: 1, liquidity: 1000000 },
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
                state: OrderState { initialized_ticks_crossed_snapshot: 1, liquidity: 1000000 },
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
    assert_eq!(periphery.place_order(salt + 1, order_key, liquidity), 64);

    // close the first one
    assert_eq!(periphery.close_order(salt, order_key), (0, 64));
    // close the second one
    assert_eq!(periphery.close_order(salt + 1, order_key), (63, 0));

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
        Zero::zero()
    );
}

#[test]
#[fork("mainnet")]
fn test_place_orders_only_one_executed_sell_token1() {
    let (pool_key, periphery) = setup();
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token1 };
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
        Zero::zero()
    );

    // place another order after the first one executed
    assert_eq!(periphery.place_order(salt + 1, order_key, liquidity), 65);

    // close the first one
    assert_eq!(periphery.close_order(salt, order_key), (63, 0));
    // close the second one
    assert_eq!(periphery.close_order(salt + 1, order_key), (0, 64));

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
        Zero::zero()
    );
}


#[test]
#[fork("mainnet")]
fn test_place_order_max_liquidity_one_price_sell_token0() {
    let (pool_key, periphery) = setup();
    assert_eq!(
        periphery
            .place_order(
                salt: 0,
                order_key: OrderKey {
                    token0: pool_key.token0, token1: pool_key.token1, tick: Zero::zero()
                },
                liquidity: 0xffffffffffffffffffffffffffffffff / 2
            ),
        10888681855593963201936311870382544 // ~= 1e16 tokens for 18 decimals
    );
}

#[test]
#[fork("mainnet")]
fn test_place_order_max_liquidity_one_price_sell_token1() {
    let (pool_key, periphery) = setup();
    assert_eq!(
        periphery
            .place_order(
                salt: 0,
                order_key: OrderKey {
                    token0: pool_key.token0,
                    token1: pool_key.token1,
                    tick: i129 { mag: LIMIT_ORDER_TICK_SPACING, sign: false }
                },
                liquidity: 0xffffffffffffffffffffffffffffffff / 2
            ),
        10890075695378402602314366742315006 // ~= 1e16 tokens for 18 decimals
    );
}

#[test]
#[fork("mainnet")]
fn test_place_order_max_liquidity_max_price_sell_token0() {
    let (pool_key, periphery) = setup();
    assert_eq!(
        periphery
            .place_order(
                salt: 0,
                order_key: OrderKey {
                    token0: pool_key.token0,
                    token1: pool_key.token1,
                    tick: i129 { mag: 693146 * LIMIT_ORDER_TICK_SPACING, sign: false }
                },
                liquidity: 0xffffffffffffffffffffffffffffffff / 2
            ),
        590334320554063
    );
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: 'OVERFLOW_AMOUNT1_DELTA')]
fn test_place_order_max_liquidity_max_price_sell_token1() {
    let (pool_key, periphery) = setup();
    periphery
        .place_order(
            salt: 0,
            order_key: OrderKey {
                token0: pool_key.token0,
                token1: pool_key.token1,
                tick: i129 { mag: 693145 * LIMIT_ORDER_TICK_SPACING, sign: false }
            },
            liquidity: 0xffffffffffffffffffffffffffffffff / 2
        );
}


#[test]
#[fork("mainnet")]
#[should_panic(expected: 'OVERFLOW_AMOUNT0_DELTA')]
fn test_place_order_max_liquidity_min_price_sell_token0() {
    let (pool_key, periphery) = setup();
    periphery
        .place_order(
            salt: 0,
            order_key: OrderKey {
                token0: pool_key.token0,
                token1: pool_key.token1,
                tick: i129 { mag: 693146 * LIMIT_ORDER_TICK_SPACING, sign: true }
            },
            liquidity: 0xffffffffffffffffffffffffffffffff / 2
        );
}

#[test]
#[fork("mainnet")]
fn test_place_order_max_liquidity_min_price_sell_token1() {
    let (pool_key, periphery) = setup();
    assert_eq!(
        periphery
            .place_order(
                salt: 0,
                order_key: OrderKey {
                    token0: pool_key.token0,
                    token1: pool_key.token1,
                    tick: i129 { mag: 693147 * LIMIT_ORDER_TICK_SPACING, sign: true }
                },
                liquidity: 0xffffffffffffffffffffffffffffffff / 2
            ),
        590334320554063
    );
}


#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Order does not exist',))]
fn test_audit_cannot_close_order_that_doest_not_exist() {
    let (pool_key, periphery) = setup();
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };

    let liquidity = 1_000_000_u128;
    assert_eq!(periphery.place_order(salt, order_key, liquidity), 64);

    let wrong_salt = 1_felt252;
    periphery.close_order(wrong_salt, order_key);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Tick wrong side selling token0',))]
fn test_audit_cannot_set_order_in_current_bounds_token0() {
    let (pool_key, periphery) = setup();

    // Set order to sell token0 at tick 100*LIMIT_ORDER_TICK_SPACING
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: 100 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    periphery.place_order(salt, order_key, liquidity);

    // Swap to set the current price between tick 100*LIMIT_ORDER_TICK_SPACING and
    // 101*LIMIT_ORDER_TICK_SPACING
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    sell_token.transfer(router().contract_address, 100);
    router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(i129 { mag: 100 * LIMIT_ORDER_TICK_SPACING, sign: false })
                    + 1,
                skip_ahead: 0
            },
            token_amount: TokenAmount {
                token: sell_token.contract_address, amount: i129 { mag: 100, sign: false }
            }
        );

    // Try to set order inside the current bounds
    periphery.place_order(1_felt252, order_key, liquidity);
}

#[test]
#[fork("mainnet")]
#[should_panic(expected: ('Tick wrong side selling token1',))]
fn test_audit_cannot_set_order_in_current_bounds_token1() {
    let (pool_key, periphery) = setup();

    // Set order to sell token1 at tick 101*LIMIT_ORDER_TICK_SPACING
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: 101 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    periphery.place_order(salt, order_key, liquidity);

    // Swap to set the current price between tick 101*LIMIT_ORDER_TICK_SPACING and
    // 100*LIMIT_ORDER_TICK_SPACING
    let sell_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    sell_token.transfer(router().contract_address, 100);
    router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(i129 { mag: 102 * LIMIT_ORDER_TICK_SPACING, sign: false })
                    - 1,
                skip_ahead: 0
            },
            token_amount: TokenAmount {
                token: sell_token.contract_address, amount: i129 { mag: 100, sign: false }
            }
        );

    periphery.place_order(1_felt252, order_key, liquidity);
}

#[test]
#[fork("mainnet")]
fn test_audit_tick_state_is_updated_on_empty_pools_positive_tick() {
    let (pool_key, periphery) = setup();

    // Initialize pool by placing an order
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: 1 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    periphery.place_order(salt, order_key, liquidity);

    // Close order and leave the pool without liquidity
    periphery.close_order(salt, order_key);
    let liquidity = ekubo_core().get_pool_liquidity(pool_key);
    assert_eq!(liquidity, 0);

    // Move the current tick
    router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(i129 { mag: 102 * LIMIT_ORDER_TICK_SPACING, sign: false }),
                skip_ahead: 0
            },
            token_amount: TokenAmount {
                token: pool_key.token1, amount: i129 { mag: 1000, sign: false }
            }
        );

    // Check that tick in pool state matches with tick in extension state
    let pool_state = ekubo_core().get_pool_price(pool_key);

    // Reading the storage
    let map_key = (pool_key.token0, pool_key.token1);
    let mut map_entry: Array<felt252> = array![];
    map_key.serialize(ref map_entry);
    let extension_pool_state_felt252 = load(
        pool_key.extension, map_entry_address(selector!("pools"), map_entry.span()), 1
    )
        .at(0);
    let extension_pool_state = StorePacking::<
        PoolState, felt252
    >::unpack(*extension_pool_state_felt252);

    assert_eq!(pool_state.tick.sign, extension_pool_state.last_tick.sign);
    assert_eq!(pool_state.tick.mag, extension_pool_state.last_tick.mag);
}

#[test]
#[fork("mainnet")]
fn test_audit_tick_state_is_updated_on_empty_pools_negative_tick() {
    let (pool_key, periphery) = setup();

    // Initialize pool by placing an order
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: 1 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };
    let liquidity = 1_000_000_u128;
    periphery.place_order(salt, order_key, liquidity);

    // Close order and leave the pool without liquidity
    periphery.close_order(salt, order_key);
    let liquidity = ekubo_core().get_pool_liquidity(pool_key);
    assert_eq!(liquidity, 0);

    // Move the current tick
    router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(i129 { mag: 1003 * LIMIT_ORDER_TICK_SPACING, sign: true }),
                skip_ahead: 0
            },
            token_amount: TokenAmount {
                token: pool_key.token0, amount: i129 { mag: 1000, sign: false }
            }
        );

    // Check that tick in pool state matches with tick in extension state
    let pool_state = ekubo_core().get_pool_price(pool_key);

    // Reading the storage
    let map_key = (pool_key.token0, pool_key.token1);
    let mut map_entry: Array<felt252> = array![];
    map_key.serialize(ref map_entry);
    let extension_pool_state_felt252 = load(
        pool_key.extension, map_entry_address(selector!("pools"), map_entry.span()), 1
    )
        .at(0);
    let extension_pool_state = StorePacking::<
        PoolState, felt252
    >::unpack(*extension_pool_state_felt252);

    assert_eq!(pool_state.tick.sign, extension_pool_state.last_tick.sign);
    assert_eq!(pool_state.tick.mag, extension_pool_state.last_tick.mag);
}

#[test]
#[fork("mainnet")]
#[should_panic(
    expected: (
        0x46a6158a16a947e5916b2a2ca68501a45e93d7110e81aa2d6438b1c57c879a3,
        0x0,
        'Only limit orders',
        0x11,
    )
)]
fn test_audit_cannot_add_liquidity_outside_the_extension() {
    let (pool_key, periphery) = setup();

    // Initialize pool
    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0, token1: pool_key.token1, tick: i129 { mag: 0, sign: false }
    };
    let liquidity = 100_000_u128;
    periphery.place_order(salt, order_key, liquidity);

    let bounds = Bounds {
        lower: i129 { mag: 100 * LIMIT_ORDER_TICK_SPACING, sign: false },
        upper: i129 { mag: 101 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };

    // Try to deposit liquidity
    let positions_contract = positions();
    positions_contract.mint_and_deposit(pool_key, bounds, liquidity);
}

#[test]
#[fork("mainnet")]
fn test_audit_extreme_orders_are_executed() {
    let (pool_key, periphery) = setup();

    let extension = ILimitOrdersDispatcher { contract_address: pool_key.extension };

    let salt = 0_felt252;
    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: 693145 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };

    let amount = periphery.place_order(salt: salt, order_key: order_key, liquidity: 100_u128);

    let sell_token = IERC20Dispatcher { contract_address: pool_key.token0 };
    sell_token.transfer(router().contract_address, 100);
    router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(
                        i129 { mag: 693145 * LIMIT_ORDER_TICK_SPACING, sign: false }
                    ),
                skip_ahead: 0
            },
            token_amount: TokenAmount {
                token: pool_key.token1, amount: i129 { mag: amount, sign: true }
            }
        );

    let (collected_amount0, collected_amount1) = periphery
        .close_order(salt: salt, order_key: order_key,);

    assert_ge!(1, collected_amount0);
    assert_eq!(collected_amount1, 0);

    assert_eq!(
        extension
            .get_order_infos(
                array![GetOrderInfoRequest { owner: periphery.contract_address, salt, order_key }]
                    .span()
            ),
        array![
            GetOrderInfoResult {
                state: OrderState { initialized_ticks_crossed_snapshot: 0, liquidity: 0 },
                executed: true,
                amount0: 0,
                amount1: 0,
            }
        ]
            .span()
    );
}

#[test]
#[fork("mainnet")]
fn test_audit_multiple_orders_same_bounds() {
    let (pool_key, periphery) = setup();

    let extension = ILimitOrdersDispatcher { contract_address: pool_key.extension };

    let salt1 = 1_felt252;
    let salt2 = 2_felt252;

    let order_key = OrderKey {
        token0: pool_key.token0,
        token1: pool_key.token1,
        tick: i129 { mag: 2 * LIMIT_ORDER_TICK_SPACING, sign: false }
    };

    periphery.place_order(salt: salt1, order_key: order_key, liquidity: 100_000_u128);
    periphery.place_order(salt: salt2, order_key: order_key, liquidity: 200_000_u128);

    let sell_token = IERC20Dispatcher { contract_address: pool_key.token1 };
    sell_token.transfer(router().contract_address, 200);
    router()
        .swap(
            node: RouteNode {
                pool_key,
                sqrt_ratio_limit: mathlib()
                    .tick_to_sqrt_ratio(i129 { mag: 3 * LIMIT_ORDER_TICK_SPACING, sign: false }),
                skip_ahead: 0
            },
            token_amount: TokenAmount {
                token: sell_token.contract_address, amount: i129 { mag: 200, sign: false }
            }
        );

    assert_eq!(
        extension
            .get_order_infos(
                array![
                    GetOrderInfoRequest {
                        owner: periphery.contract_address, salt: salt1, order_key
                    },
                    GetOrderInfoRequest {
                        owner: periphery.contract_address, salt: salt2, order_key
                    }
                ]
                    .span()
            ),
        array![
            GetOrderInfoResult {
                state: OrderState {
                    initialized_ticks_crossed_snapshot: 1, liquidity: 100_000_u128
                },
                executed: true,
                amount0: 0,
                amount1: 6,
            },
            GetOrderInfoResult {
                state: OrderState {
                    initialized_ticks_crossed_snapshot: 1, liquidity: 200_000_u128
                },
                executed: true,
                amount0: 0,
                amount1: 12,
            }
        ]
            .span()
    );

    let (received_amount_t0_1, received_amount_t1_1) = periphery.close_order(salt1, order_key);
    let (received_amount_t0_2, received_amount_t1_2) = periphery.close_order(salt2, order_key);

    assert_eq!(received_amount_t0_1, 0);
    assert_eq!(received_amount_t0_2, 0);

    assert_eq!(received_amount_t1_1, 6);
    assert_eq!(received_amount_t1_2, 12);
}
