use starknet::{ContractAddress, ClassHash};
use pramb_cover::pramb_cover::PrambCover::{TokenCapacity, Protocol, UserCover};
#[starknet::interface]
trait IPrambCover<TContractState> {
    // admin functions
    fn create_protocol(ref self: TContractState, _name: felt252, _rate: u128);
    fn add_token_cover(
        ref self: TContractState,
        _protocol_name: felt252,
        _token: ContractAddress,
        _max_capacity: u256
    );
    fn update_admin(ref self: TContractState, _new_admin: ContractAddress);
    fn update_rate_protocol(ref self: TContractState, _name: felt252, _new_rate: u128);
    fn update_capacity_token_protocol(
        ref self: TContractState,
        _protocol_name: felt252,
        _token: ContractAddress,
        _new_max_capacity: u256,
        _current_capacity: u256
    );
    fn withdraw_treasure(ref self: TContractState, _token: ContractAddress, _amount: u128);
    fn upgrage(ref self: TContractState, _new_class_hash: ClassHash);

    // user functions
    fn buy_cover(
        ref self: TContractState,
        _protocol_name: felt252,
        _days: u64,
        _amount_cover: u256,
        _token: ContractAddress,
        _amount: u256,
    );
    fn extend_cover(
        ref self: TContractState,
        _cover_id: u128,
        _protocol_name: felt252,
        _extend_days: u64,
        _token: ContractAddress,
        _amount: u256,
    );

    // //view function
    fn get_protocol(self: @TContractState, _name: felt252) -> Protocol;
    fn get_token_capacity(
        self: @TContractState, _protocol_name: felt252, _token: ContractAddress
    ) -> TokenCapacity;
    fn get_user_cover(
        self: @TContractState, _cover_id: u128
    ) -> UserCover;
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
}

#[starknet::contract]
mod PrambCover {
    use core::traits::TryInto;
    use starknet::SyscallResultTrait;
    use starknet::event::EventEmitter;
    const BASE_DENOMINATOR: felt252 = 1_000_000;
    const DEV: felt252 = 0x0187623be1669117F3bd4DE38E86B01E2493a28ccBa1f669Ff0D7a9d9D6Ca571;
    const TREASURE: felt252 = 0x0187623be1669117F3bd4DE38E86B01E2493a28ccBa1f669Ff0D7a9d9D6Ca571;
    const ADMIN: felt252 = 0x0187623be1669117F3bd4DE38E86B01E2493a28ccBa1f669Ff0D7a9d9D6Ca571;

    use starknet::{ContractAddress, ClassHash};
    use starknet::{
        get_caller_address, get_contract_address, contract_address_try_from_felt252,
        replace_class_syscall, get_block_timestamp
    };
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};


    pub mod Pramb_Cover_ERRs {
        pub const E_NOT_ENOUGHT_BALANCE: felt252 = 'Not enough balance';
        pub const E_NOT_OWNER: felt252 = 'Not owner';
        pub const E_PROTOCOL_NOT_FOUND: felt252 = 'Protocol not found';
        pub const E_INVALID_TOKEN: felt252 = 'Invalid token';
        pub const E_EXISTED_TOKEN: felt252 = 'Token existed';
        pub const E_NOT_EXISTED_TOKEN: felt252 = 'Token not existed';
        pub const E_MAX_CAPACITY: felt252 = 'Max capacity';
        pub const E_NOT_EXISTED_USER_COVER: felt252 = 'User cover not existed';
        pub const E_OVER_MAX_DURATION: felt252 = 'Over max duration';
    }

    #[storage]
    struct Storage {
        current_id: u128,
        admin: ContractAddress,
        protocols: LegacyMap<felt252, Protocol>,
        user_covers: LegacyMap<u128, UserCover>,
        max_capacity_tokens: LegacyMap<(felt252, ContractAddress), TokenCapacity>
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct Protocol {
        name: felt252,
        rate_per_day: u128,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct TokenCapacity {
        token: ContractAddress,
        max_capacity: u256,
        current_capacity: u256,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct UserCover {
        cover_id: u128,
        addr: ContractAddress,
        amount: u256,
        cost: u256,
        token: ContractAddress,
        protocol_name: felt252,
        start_time: u64,
        end_time: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CreatePotocolEvent: CreatePotocolEvent,
        AddTokenCoverEvent: AddTokenCoverEvent,
        CreateUserCoverEvent: CreateUserCoverEvent,
        ExtendUserCoverEvent: ExtendUserCoverEvent,
        Upgraded: Upgraded
    }

    #[derive(Drop, starknet::Event)]
    struct CreatePotocolEvent {
        name: felt252,
        rate: u128,
    }

    #[derive(Drop, starknet::Event)]
    struct AddTokenCoverEvent {
        token: ContractAddress,
        max_capacity: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct CreateUserCoverEvent {
        cover_id: u128,
        user_addr: ContractAddress,
        protocol_name: felt252,
        token: ContractAddress,
        amount: u256,
        cost: u256,
        start_time: u64,
        end_time: u64,
        current_capacity: u256
    }

    #[derive(Drop, starknet::Event)]
    struct ExtendUserCoverEvent {
        cover_id: u128,
        user_addr: ContractAddress,
        protocol_name: felt252,
        token: ContractAddress,
        amount: u256,
        cost: u256,
        start_time: u64,
        end_time: u64,
        current_capacity: u256
    }

    /// Emitted when the contract is upgraded.
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct Upgraded {
        pub class_hash: ClassHash
    }


    #[constructor]
    fn constructor(ref self: ContractState) {
        let admin_addr = contract_address_try_from_felt252(ADMIN).unwrap();
        self.admin.write(admin_addr);
        self.current_id.write(0);
    }

    #[abi(embed_v0)]
    impl PrambCover of super::IPrambCover<ContractState> {
        // admin functions
        fn create_protocol(ref self: ContractState, _name: felt252, _rate: u128) {
            let sender_addr = get_caller_address();
            let admin = self.admin.read();
            assert(sender_addr == admin, Pramb_Cover_ERRs::E_NOT_OWNER);
            // check existed protocol
            let protocols = self.protocols.read(_name);
            assert(protocols.name != _name, Pramb_Cover_ERRs::E_EXISTED_TOKEN);
            let protocol = Protocol { name: _name, rate_per_day: _rate };
            self.protocols.write(_name,protocol);
            self.emit(CreatePotocolEvent { name: _name, rate: _rate });
        }
        fn add_token_cover(
            ref self: ContractState,
            _protocol_name: felt252,
            _token: ContractAddress,
            _max_capacity: u256
        ) {
            let sender_addr = get_caller_address();
            let admin = self.admin.read();
            assert(sender_addr == admin, Pramb_Cover_ERRs::E_NOT_OWNER);
            // check existed protocol
            let protocols = self.protocols.read(_protocol_name);
            assert(protocols.name == _protocol_name, Pramb_Cover_ERRs::E_PROTOCOL_NOT_FOUND);
            // check existed token
            let token_capacity = self.max_capacity_tokens.read((_protocol_name, _token));
            assert(token_capacity.token != _token, Pramb_Cover_ERRs::E_EXISTED_TOKEN);
            let create_token_capacity = TokenCapacity {
                token: _token, max_capacity: _max_capacity, current_capacity: 0
            };
            self.max_capacity_tokens.write((_protocol_name, _token),create_token_capacity);
            self.emit(AddTokenCoverEvent { token: _token, max_capacity: _max_capacity });
        }
        fn update_admin(ref self: ContractState, _new_admin: ContractAddress) {
            let dev_addr = contract_address_try_from_felt252(DEV).unwrap();
            let sender_addr = get_caller_address();
            let admin = self.admin.read();
            assert(sender_addr == admin || sender_addr == dev_addr, Pramb_Cover_ERRs::E_NOT_OWNER);
            self.admin.write(_new_admin);
        }
        fn update_rate_protocol(ref self: ContractState, _name: felt252, _new_rate: u128) {
            let sender_addr = get_caller_address();
            let admin = self.admin.read();
            assert(sender_addr == admin, Pramb_Cover_ERRs::E_NOT_OWNER);
            // check existed protocol
            let protocols = self.protocols.read(_name);
            assert(protocols.name == _name, Pramb_Cover_ERRs::E_PROTOCOL_NOT_FOUND);
            let update_protocol = Protocol { name: _name, rate_per_day: _new_rate };
            self.protocols.write(_name,update_protocol);
        }
        fn update_capacity_token_protocol(
            ref self: ContractState,
            _protocol_name: felt252,
            _token: ContractAddress,
            _new_max_capacity: u256,
            _current_capacity: u256
        ) {
            let sender_addr = get_caller_address();
            let admin = self.admin.read();
            assert(sender_addr == admin, Pramb_Cover_ERRs::E_NOT_OWNER);
            // check existed protocol
            let protocols = self.protocols.read(_protocol_name);
            assert(protocols.name == _protocol_name, Pramb_Cover_ERRs::E_PROTOCOL_NOT_FOUND);
            // check existed token
            let token_capacity = self.max_capacity_tokens.read((_protocol_name, _token));
            assert(token_capacity.token == _token, Pramb_Cover_ERRs::E_NOT_EXISTED_TOKEN);
            let update_token_capacity = TokenCapacity {
                token: _token, max_capacity: _new_max_capacity, current_capacity: _current_capacity
            };
            self.max_capacity_tokens.write((_protocol_name, _token),update_token_capacity);
        }
        fn withdraw_treasure(ref self: ContractState, _token: ContractAddress, _amount: u128) {
            let dev_addr = contract_address_try_from_felt252(DEV).unwrap();
            let sender_addr = get_caller_address();
            let admin = self.admin.read();
            let treasure_addr = contract_address_try_from_felt252(TREASURE).unwrap();
            assert(
                sender_addr == admin || sender_addr == dev_addr || sender_addr == treasure_addr,
                Pramb_Cover_ERRs::E_NOT_OWNER
            );
            // withdraw
            let erc20_dispatcher = IERC20Dispatcher { contract_address: _token };
            let amount: u256 = _amount.into();
            erc20_dispatcher.transfer(sender_addr, amount);
        }
        fn upgrage(ref self: ContractState, _new_class_hash: ClassHash) {
            let sender_addr = get_caller_address();
            let dev = contract_address_try_from_felt252(DEV).unwrap();
            assert(sender_addr == dev, Pramb_Cover_ERRs::E_NOT_OWNER);
            assert(!_new_class_hash.is_zero(), 'Invalid class hash');
            replace_class_syscall(_new_class_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: _new_class_hash });
        }

        // user functions
        fn buy_cover(
            ref self: ContractState,
            _protocol_name: felt252,
            _days: u64,
            _amount_cover: u256,
            _token: ContractAddress,
            _amount: u256,
        ) {
            let sender_addr = get_caller_address();
            // check existed protocol
            let protocols = self.protocols.read(_protocol_name);
            assert(protocols.name == _protocol_name, Pramb_Cover_ERRs::E_PROTOCOL_NOT_FOUND);
            // check existed token
            let token_capacity = self.max_capacity_tokens.read((_protocol_name, _token));
            assert(token_capacity.token == _token, Pramb_Cover_ERRs::E_NOT_EXISTED_TOKEN);
            // check max capacity
            assert(
                token_capacity.current_capacity + _amount_cover <= token_capacity.max_capacity,
                Pramb_Cover_ERRs::E_MAX_CAPACITY
            );
            // check max duration
            assert(_days <= 365, Pramb_Cover_ERRs::E_OVER_MAX_DURATION);
            // check balance
            let current_id = self.current_id.read();
            let yel: u256 = (protocols.rate_per_day * _days.into()).into();
            let amount_cost = yel * _amount_cover / BASE_DENOMINATOR.into();

            let erc20_dispatcher = IERC20Dispatcher { contract_address: _token };
            erc20_dispatcher
                .transfer_from(
                    sender_addr, contract_address_try_from_felt252(TREASURE).unwrap(), amount_cost
                );

            let now = get_block_timestamp();
            let end_time = now + (_days * 86400);

            let user_cover = UserCover {
                cover_id: current_id,
                addr: sender_addr,
                amount: _amount_cover,
                cost: amount_cost,
                token: _token,
                protocol_name: _protocol_name,
                start_time: now,
                end_time,
            };

            self.user_covers.write(current_id,user_cover);
            self.current_id.write(current_id + 1);
            self
                .max_capacity_tokens
                .write(
                    (_protocol_name, _token),
                    TokenCapacity {
                        token: _token,
                        max_capacity: token_capacity.max_capacity,
                        current_capacity: token_capacity.current_capacity + _amount_cover
                    }
                );
            self
                .emit(
                    CreateUserCoverEvent {
                        cover_id: current_id,
                        user_addr: sender_addr,
                        protocol_name: _protocol_name,
                        token: _token,
                        amount: _amount_cover,
                        cost: amount_cost,
                        start_time: now,
                        end_time,
                        current_capacity: token_capacity.current_capacity + _amount_cover
                    }
                );
        }

        fn extend_cover(
            ref self: ContractState,
            _cover_id: u128,
            _protocol_name: felt252,
            _extend_days: u64,
            _token: ContractAddress,
            _amount: u256,
        ) {
            let sender_addr = get_caller_address();
            // check existed protocol
            let protocols = self.protocols.read(_protocol_name);
            assert(protocols.name == _protocol_name, Pramb_Cover_ERRs::E_PROTOCOL_NOT_FOUND);
            // check existed token
            let token_capacity = self.max_capacity_tokens.read((_protocol_name, _token));
            assert(token_capacity.token == _token, Pramb_Cover_ERRs::E_NOT_EXISTED_TOKEN);

            // chek user cover
            let user_cover = self.user_covers.read(_cover_id);
            assert(user_cover.addr == sender_addr, Pramb_Cover_ERRs::E_NOT_EXISTED_USER_COVER);

            let end_time = user_cover.end_time + (_extend_days * 86400);

            // check max duration
            assert(
                (end_time - user_cover.start_time) / 86400 <= 365,
                Pramb_Cover_ERRs::E_OVER_MAX_DURATION
            );

            let yel: u256 = (protocols.rate_per_day * _extend_days.into()).into();
            let amount_cost = yel * user_cover.amount / BASE_DENOMINATOR.into();

            let erc20_dispatcher = IERC20Dispatcher { contract_address: _token };
            erc20_dispatcher
                .transfer_from(
                    sender_addr, contract_address_try_from_felt252(TREASURE).unwrap(), amount_cost
                );

            let new_user_cover = UserCover {
                cover_id: _cover_id,
                addr: sender_addr,
                amount: user_cover.amount,
                cost: user_cover.cost + amount_cost,
                token: _token,
                protocol_name: _protocol_name,
                start_time: user_cover.start_time,
                end_time,
            };

            self.user_covers.write(_cover_id,new_user_cover);
            self
                .emit(
                    ExtendUserCoverEvent {
                        cover_id: _cover_id,
                        user_addr: sender_addr,
                        protocol_name: _protocol_name,
                        token: _token,
                        amount: user_cover.amount,
                        cost: user_cover.cost + amount_cost,
                        start_time: user_cover.start_time,
                        end_time,
                        current_capacity: token_capacity.current_capacity
                    }
                );
        }

        // //view function
        fn get_protocol(self: @ContractState, _name: felt252) -> Protocol {
            let protocols = self.protocols.read(_name);
            protocols
        }
        fn get_token_capacity(
            self: @ContractState, _protocol_name: felt252, _token: ContractAddress
        ) -> TokenCapacity {
            let token_capacity = self.max_capacity_tokens.read((_protocol_name, _token));
            token_capacity
        }
        fn get_user_cover(
            self: @ContractState, _cover_id: u128
        ) -> UserCover {
            let user_cover = self.user_covers.read(_cover_id);
            user_cover
        }
    }
}
