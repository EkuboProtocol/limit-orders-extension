use ekubo::interfaces::core::{ICoreDispatcherTrait, ICoreDispatcher, IExtensionDispatcher};
use ekubo::interfaces::positions::{IPositionsDispatcher};
use ekubo::interfaces::router::{IRouterDispatcher};
use ekubo::types::call_points::{CallPoints};
use ekubo::types::keys::{PoolKey};
use ekubo_limit_orders_extension::test_token::{IERC20Dispatcher};
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
        .deploy(@array![get_contract_address().into(), core.contract_address.into(),])
        .expect('Deploy failed');

    IExtensionDispatcher { contract_address }
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

fn setup(starting_balance: u256, fee: u128, tick_spacing: u128) -> PoolKey {
    let limit_orders = deploy_limit_orders(ekubo_core());
    let token_class = declare("TestToken").unwrap().contract_class();
    let owner = get_contract_address();
    let (tokenA, tokenB) = (
        deploy_token(token_class, owner, starting_balance),
        deploy_token(token_class, owner, starting_balance)
    );
    let (token0, token1) = if (tokenA.contract_address < tokenB.contract_address) {
        (tokenA, tokenB)
    } else {
        (tokenB, tokenA)
    };

    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee: fee,
        tick_spacing: tick_spacing,
        extension: limit_orders.contract_address,
    };

    pool_key
}

#[test]
#[fork("mainnet")]
fn test_constructor_sets_call_points() {
    let pool_key = setup(starting_balance: 1000, fee: 0, tick_spacing: 100);
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

