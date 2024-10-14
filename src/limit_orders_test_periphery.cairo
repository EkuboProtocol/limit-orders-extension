use ekubo_limit_orders_extension::limit_orders::OrderKey;

#[starknet::interface]
pub trait ILimitOrdersTestPeriphery<TContractState> {
    fn place_order(
        ref self: TContractState, salt: felt252, order_key: OrderKey, liquidity: u128
    ) -> u128;
    fn close_order(ref self: TContractState, salt: felt252, order_key: OrderKey) -> (u128, u128);
}

#[starknet::contract]
mod LimitOrdersTestPeriphery {
    use core::num::traits::{Zero};
    use ekubo::components::shared_locker::{
        call_core_with_callback, consume_callback_data, forward_lock
    };
    use ekubo::components::util::{serialize};
    use ekubo::interfaces::core::{
        IForwardeeDispatcher, ICoreDispatcher, ICoreDispatcherTrait, ILocker
    };
    use ekubo_limit_orders_extension::limit_orders::{
        LimitOrders, ILimitOrdersDispatcher, PlaceOrderForwardCallbackData,
        CloseOrderForwardCallbackData, ForwardCallbackData, ForwardCallbackResult
    };
    use ekubo_limit_orders_extension::test_token::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::{StoragePointerWriteAccess};
    use starknet::{get_contract_address};
    use super::{OrderKey, ILimitOrdersTestPeriphery};

    #[storage]
    struct Storage {
        core: ICoreDispatcher,
        limit_orders: ILimitOrdersDispatcher,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, core: ICoreDispatcher, limit_orders: ILimitOrdersDispatcher
    ) {
        self.core.write(core);
        self.limit_orders.write(limit_orders);
    }

    #[abi(embed_v0)]
    impl LockCallback of ILocker<ContractState> {
        fn locked(ref self: ContractState, id: u32, mut data: Span<felt252>) -> Span<felt252> {
            let core = self.core.read();
            match consume_callback_data::<ForwardCallbackData>(core, data) {
                ForwardCallbackData::PlaceOrder(data) => {
                    let result: ForwardCallbackResult = forward_lock(
                        core,
                        IForwardeeDispatcher {
                            contract_address: self.limit_orders.read().contract_address
                        },
                        @ForwardCallbackData::PlaceOrder(data)
                    );

                    // pay from this address
                    if let ForwardCallbackResult::PlaceOrder(amount) = result {
                        let pay_token = IERC20Dispatcher {
                            contract_address: if (data
                                .order_key
                                .tick
                                .mag % LimitOrders::DOUBLE_LIMIT_ORDER_TICK_SPACING)
                                .is_non_zero() {
                                data.order_key.token1
                            } else {
                                data.order_key.token0
                            }
                        };
                        pay_token.approve(core.contract_address, amount.into());
                        core.pay(pay_token.contract_address);
                    };

                    serialize(@result).span()
                },
                ForwardCallbackData::CloseOrder(data) => {
                    let result: ForwardCallbackResult = forward_lock(
                        core,
                        IForwardeeDispatcher {
                            contract_address: self.limit_orders.read().contract_address
                        },
                        @ForwardCallbackData::CloseOrder(data)
                    );

                    // withdraw it to self
                    if let ForwardCallbackResult::CloseOrder((amount0, amount1)) = result {
                        if amount0.is_non_zero() {
                            core.withdraw(data.order_key.token0, get_contract_address(), amount0);
                        }
                        if amount1.is_non_zero() {
                            core.withdraw(data.order_key.token1, get_contract_address(), amount1);
                        }
                    };

                    serialize(@result).span()
                },
            }
        }
    }

    #[abi(embed_v0)]
    impl LimitOrdersTestPeripheryImpl of ILimitOrdersTestPeriphery<ContractState> {
        fn place_order(
            ref self: ContractState, salt: felt252, order_key: OrderKey, liquidity: u128
        ) -> u128 {
            match call_core_with_callback::<
                ForwardCallbackData, ForwardCallbackResult
            >(
                self.core.read(),
                @ForwardCallbackData::PlaceOrder(
                    PlaceOrderForwardCallbackData { salt, order_key, liquidity }
                )
            ) {
                ForwardCallbackResult::PlaceOrder(amount) => { amount },
                ForwardCallbackResult::CloseOrder(_) => { panic!("unexpected result") }
            }
        }
        fn close_order(
            ref self: ContractState, salt: felt252, order_key: OrderKey
        ) -> (u128, u128) {
            match call_core_with_callback::<
                ForwardCallbackData, ForwardCallbackResult
            >(
                self.core.read(),
                @ForwardCallbackData::CloseOrder(CloseOrderForwardCallbackData { salt, order_key })
            ) {
                ForwardCallbackResult::PlaceOrder => { panic!("unexpected result") },
                ForwardCallbackResult::CloseOrder((amount0, amount1)) => { (amount0, amount1) }
            }
        }
    }
}

