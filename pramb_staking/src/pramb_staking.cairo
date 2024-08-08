use starknet::{ContractAddress, ClassHash};
use pramb_staking::pramb_staking::PrambStaking::{PoolInfo, UserStakingDetail, StakingOption};
#[starknet::interface]
trait IPrambStaking<TContractState> {
    // admin functions
    fn create_protocol(
        ref self: TContractState, _stake_token: ContractAddress, _reward_token: ContractAddress
    );
    fn add_staking_option(
        ref self: TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _index_option: u64,
        _day: u64,
        _fixed_yield: u128
    );
    fn withdraw_treasure(ref self: TContractState, _token: ContractAddress, _amount: u256);
    fn stop_pool(
        ref self: TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _paused: bool
    );
    fn update_staking_option(
        ref self: TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _index_option: u64,
        _day: u64,
        _fixed_yield: u128
    );
    fn set_admin(ref self: TContractState, _admin: ContractAddress);
    fn upgrade(ref self: TContractState, _new_class_hash: ClassHash);

    // user functions
    fn stake_token(
        ref self: TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _amount: u256,
        staking_option_index: u64
    );
    fn claim_reward(
        ref self: TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _stake_id: u128
    );
    fn withdraw_token(
        ref self: TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _stake_id: u128
    );

    //view functions
    fn get_pool_info(
        self: @TContractState, _stake_token: ContractAddress, _reward_token: ContractAddress
    ) -> PoolInfo;
    fn get_staking_option(
        self: @TContractState,
        _stake_token: ContractAddress,
        _reward_token: ContractAddress,
        _index_option: u64
    ) -> StakingOption;
    fn get_user_staking_detail(self: @TContractState, _stake_id: u128) -> UserStakingDetail;
    fn caculate_pending_reward(self: @TContractState, _stake_id: u128) -> u256;
}

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256
    ) -> bool;
}

#[starknet::contract]
mod PrambStaking {
    use core::option::OptionTrait;
    use core::traits::Into;
    use core::Array;
    use core::traits::TryInto;
    use starknet::SyscallResultTrait;
    use starknet::event::EventEmitter;
    const BASE_DENOMINATOR: felt252 = 10_000;
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
        pub const ERROR_ONLY_ADMIN: felt252 = 'Only admin';
        pub const ERROR_POOL_EXIST: felt252 = 'Pool already exist';
        pub const ERROR_COIN_NOT_EXIST: felt252 = 'Coin not exist';
        pub const ERROR_PASS_START_TIME: felt252 = 'Pass start time';
        pub const ERROR_MUST_BE_INFERIOR_TO_TWENTY: felt252 = 'Must be inferior to 20';
        pub const ERROR_POOL_LIMIT_ZERO: felt252 = 'Pool limit zero';
        pub const ERROR_INSUFFICIENT_BALANCE: felt252 = 'Insufficient balance';
        pub const ERROR_POOL_NOT_EXIST: felt252 = 'Pool not exist';
        pub const ERROR_STAKE_ABOVE_LIMIT: felt252 = 'Stake above limit';
        pub const ERROR_NO_STAKE: felt252 = 'No stake';
        pub const ERROR_NO_LIMIT_SET: felt252 = 'No limit set';
        pub const ERROR_LIMIT_MUST_BE_HIGHER: felt252 = 'Limit must be higher';
        pub const ERROR_POOL_STARTED: felt252 = 'Pool started';
        pub const ERROR_END_TIME_EARLIER_THAN_START_TIME: felt252 = 'End time under start time';
        pub const ERROR_POOL_END: felt252 = 'Pool end';
        pub const ERROR_REWARD_MAX: felt252 = 'Reward max';
        pub const ERROR_WRONG_UID: felt252 = 'Wrong uid';
        pub const ERROR_SAME_TOKEN: felt252 = 'Same token';
        pub const ERROR_WRONG_STAKING_OPTIONS: felt252 = 'Wrong staking options';
        pub const ERROR_STAKE_ID_NOTFOUND: felt252 = 'Stake id not found';
        pub const ERROR_NOT_TIME_TO_WITHDRAW: felt252 = 'Not time to withdraw';
        pub const ERROR_REWARD_NOT_MATCH_STAKE_ID: felt252 = 'Reward not match stake id';
    }

    #[storage]
    struct Storage {
        current_id: u128,
        admin: ContractAddress,
        pools: LegacyMap<(ContractAddress, ContractAddress), PoolInfo>,
        staking_options: LegacyMap<(ContractAddress, ContractAddress, u64), StakingOption>,
        stakings_details: LegacyMap<u128, UserStakingDetail>,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct PoolInfo {
        total_staked: u256,
        paused: bool,
        stake_token: ContractAddress,
        reward_token: ContractAddress,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct StakingOption {
        days: u64,
        fixed_yield: u128
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct UserStakingDetail {
        stake_id: u128,
        user_addr: ContractAddress,
        amount: u256,
        reward_debt: u256,
        fixed_yield: u128,
        start_time: u64,
        end_time: u64,
        last_time_claimed: u64,
        stake_token: ContractAddress,
        reward_token: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Upgraded: Upgraded,
        CreatePoolEvent: CreatePoolEvent,
        DepositEvent: DepositEvent,
        WithdrawEvent: WithdrawEvent,
        ClaimRewardEvent: ClaimRewardEvent,
    }

    #[derive(Drop, starknet::Event)]
    struct CreatePoolEvent {
        stake_token: ContractAddress,
        reward_token: ContractAddress,
        user_addr: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct DepositEvent {
        stake_id: u128,
        user_addr: ContractAddress,
        amount: u256,
        stake_token: ContractAddress,
        reward_token: ContractAddress,
        fixed_yield: u128,
        start_time: u64,
        end_time: u64,
        reward_debt: u256,
        last_time_claimed: u64
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawEvent {
        stake_id: u128,
        user_addr: ContractAddress,
        amount: u256,
        stake_token: ContractAddress,
        reward_token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ClaimRewardEvent {
        stake_id: u128,
        user_addr: ContractAddress,
        amount: u256,
        stake_token: ContractAddress,
        reward_token: ContractAddress,
        last_time_claimed: u64,
        fixed_yield: u128,
        reward_debt: u256,
        start_time: u64,
        end_time: u64,
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
    impl PrambStaking of super::IPrambStaking<ContractState> {
        // admin functions
        fn create_protocol(
            ref self: ContractState, _stake_token: ContractAddress, _reward_token: ContractAddress
        ) {
            let sender_addr = get_caller_address();
            let admin_addr = self.admin.read();
            assert(sender_addr == admin_addr, Pramb_Cover_ERRs::ERROR_ONLY_ADMIN);
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_EXIST
            );
            let pool_info = PoolInfo {
                total_staked: 0,
                paused: false,
                stake_token: _stake_token,
                reward_token: _reward_token,
            };
            self.pools.write((_stake_token, _reward_token), pool_info);
            let create_pool_event = CreatePoolEvent {
                stake_token: _stake_token, reward_token: _reward_token, user_addr: sender_addr,
            };
            self.emit(create_pool_event);
        }
        // admin functions

        // admin functions
        fn add_staking_option(
            ref self: ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _index_option: u64,
            _day: u64,
            _fixed_yield: u128
        ) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let admin_addr = self.admin.read();
            assert(sender_addr == admin_addr, Pramb_Cover_ERRs::ERROR_ONLY_ADMIN);
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            // add staking option
            let staking_option = StakingOption { days: _day, fixed_yield: _fixed_yield, };
            self
                .staking_options
                .write((_stake_token, _reward_token, _index_option), staking_option);
        }

        fn withdraw_treasure(ref self: ContractState, _token: ContractAddress, _amount: u256) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let treasure_addr = contract_address_try_from_felt252(TREASURE).unwrap();
            let dev_addr = contract_address_try_from_felt252(DEV).unwrap();
            assert(
                sender_addr == dev_addr || sender_addr == treasure_addr,
                Pramb_Cover_ERRs::ERROR_ONLY_ADMIN
            );
            let erc20_dispatcher = IERC20Dispatcher { contract_address: _token };
            // transfer token
            erc20_dispatcher.transfer(sender_addr, _amount);
        }

        fn stop_pool(
            ref self: ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _paused: bool
        ) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let admin_addr = self.admin.read();
            assert(sender_addr == admin_addr, Pramb_Cover_ERRs::ERROR_ONLY_ADMIN);
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            //update pool
            let new_pool = PoolInfo {
                total_staked: pool.total_staked,
                paused: _paused,
                stake_token: _stake_token,
                reward_token: _reward_token,
            };
            self.pools.write((_stake_token, _reward_token), new_pool);
        }

        fn update_staking_option(
            ref self: ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _index_option: u64,
            _day: u64,
            _fixed_yield: u128
        ) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let admin_addr = self.admin.read();
            assert(sender_addr == admin_addr, Pramb_Cover_ERRs::ERROR_ONLY_ADMIN);
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            // check staking option
            let staking_option = self
                .staking_options
                .read((_stake_token, _reward_token, _index_option));
            assert(staking_option.days > 0, Pramb_Cover_ERRs::ERROR_WRONG_STAKING_OPTIONS);
            // update staking option
            let new_staking_option = StakingOption { days: _day, fixed_yield: _fixed_yield, };
            self
                .staking_options
                .write((_stake_token, _reward_token, _index_option), new_staking_option);
        }

        fn set_admin(ref self: ContractState, _admin: ContractAddress) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let admin_addr = self.admin.read();
            let dev_addr = contract_address_try_from_felt252(DEV).unwrap();
            assert(
                sender_addr == admin_addr || sender_addr == dev_addr,
                Pramb_Cover_ERRs::ERROR_ONLY_ADMIN
            );
            self.admin.write(_admin);
        }

        fn upgrade(ref self: ContractState, _new_class_hash: ClassHash) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let admin_addr = self.admin.read();
            let dev_addr = contract_address_try_from_felt252(DEV).unwrap();
            assert(
                sender_addr == admin_addr || sender_addr == dev_addr,
                Pramb_Cover_ERRs::ERROR_ONLY_ADMIN
            );
            replace_class_syscall(_new_class_hash).unwrap_syscall();
            let upgraded_event = Upgraded { class_hash: _new_class_hash, };
            self.emit(upgraded_event);
        }

        // user functions
        fn stake_token(
            ref self: ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _amount: u256,
            staking_option_index: u64
        ) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            let staking_option = self
                .staking_options
                .read((_stake_token, _reward_token, staking_option_index));
            assert(staking_option.days > 0, Pramb_Cover_ERRs::ERROR_WRONG_STAKING_OPTIONS);

            let current_time = get_block_timestamp();
            let start_time = current_time;
            let end_time = current_time + (staking_option.days * 24 * 60 * 60);

            let current_stake_id = self.current_id.read() + 1;
            let amount_reward_paid = self
                .total_can_claim_reward(_amount, staking_option.fixed_yield, start_time, end_time);

            let erc20_dispatcher = IERC20Dispatcher { contract_address: _stake_token };
            // transfer to treasure
            erc20_dispatcher
                .transfer_from(
                    sender_addr,
                    contract_address_try_from_felt252(TREASURE).unwrap(),
                    _amount - amount_reward_paid
                );

            // transfer to contract
            erc20_dispatcher.transfer_from(sender_addr, get_contract_address(), amount_reward_paid);

            // update current id
            self.current_id.write(current_stake_id);
            // update staking pool
            let new_pool = PoolInfo {
                total_staked: pool.total_staked + _amount,
                paused: pool.paused,
                stake_token: _stake_token,
                reward_token: _reward_token,
            };
            self.pools.write((_stake_token, _reward_token), new_pool);
            // update staking details
            let user_staking_detail = UserStakingDetail {
                stake_id: current_stake_id,
                user_addr: sender_addr,
                amount: _amount,
                reward_debt: 0,
                fixed_yield: staking_option.fixed_yield,
                start_time: start_time,
                end_time: end_time,
                last_time_claimed: 0,
                stake_token: _stake_token,
                reward_token: _reward_token,
            };
            self.stakings_details.write(current_stake_id, user_staking_detail);

            let deposit_event = DepositEvent {
                stake_id: current_stake_id,
                user_addr: sender_addr,
                amount: _amount,
                stake_token: _stake_token,
                reward_token: _reward_token,
                fixed_yield: staking_option.fixed_yield,
                start_time: start_time,
                end_time: end_time,
                reward_debt: 0,
                last_time_claimed: 0,
            };
            self.emit(deposit_event);
        }

        fn claim_reward(
            ref self: ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _stake_id: u128
        ) {
            // implementation goes here
            let sender_addr = get_caller_address();
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            let user_staking_detail = self.stakings_details.read(_stake_id);
            assert(
                user_staking_detail.stake_id == _stake_id, Pramb_Cover_ERRs::ERROR_STAKE_ID_NOTFOUND
            );
            // check user
            assert(user_staking_detail.user_addr == sender_addr, Pramb_Cover_ERRs::ERROR_NO_STAKE);

            // calculate reward
            let pending_reward = self
                .cal_pending_reward(
                    user_staking_detail.amount,
                    user_staking_detail.reward_debt,
                    user_staking_detail.fixed_yield,
                    user_staking_detail.last_time_claimed,
                    user_staking_detail.start_time,
                    user_staking_detail.end_time
                );
            let erc20_dispatcher = IERC20Dispatcher { contract_address: _reward_token };
            // transfer reward
            erc20_dispatcher.transfer(sender_addr, pending_reward);
            // update user staking detail
            let new_user_staking_detail = UserStakingDetail {
                stake_id: user_staking_detail.stake_id,
                user_addr: user_staking_detail.user_addr,
                amount: user_staking_detail.amount,
                reward_debt: user_staking_detail.reward_debt + pending_reward,
                fixed_yield: user_staking_detail.fixed_yield,
                start_time: user_staking_detail.start_time,
                end_time: user_staking_detail.end_time,
                last_time_claimed: get_block_timestamp(),
                stake_token: user_staking_detail.stake_token,
                reward_token: user_staking_detail.reward_token,
            };

            // emit event
            let claim_reward_event = ClaimRewardEvent {
                stake_id: _stake_id,
                user_addr: sender_addr,
                amount: pending_reward,
                stake_token: _stake_token,
                reward_token: _reward_token,
                last_time_claimed: get_block_timestamp(),
                fixed_yield: user_staking_detail.fixed_yield,
                reward_debt: user_staking_detail.reward_debt + pending_reward,
                start_time: user_staking_detail.start_time,
                end_time: user_staking_detail.end_time,
            };

            self.stakings_details.write(_stake_id, new_user_staking_detail);
            self.emit(claim_reward_event);
        }

        fn withdraw_token(
            ref self: ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _stake_id: u128
        ) { // implementation goes here
            let sender_addr = get_caller_address();
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            let user_staking_detail = self.stakings_details.read(_stake_id);
            assert(
                user_staking_detail.stake_id == _stake_id, Pramb_Cover_ERRs::ERROR_STAKE_ID_NOTFOUND
            );
            // check user
            assert(user_staking_detail.user_addr == sender_addr, Pramb_Cover_ERRs::ERROR_NO_STAKE);
            // check time
            assert(
                get_block_timestamp() >= user_staking_detail.end_time,
                Pramb_Cover_ERRs::ERROR_NOT_TIME_TO_WITHDRAW
            );
            // check reward
            let pending_reward = self
                .cal_pending_reward(
                    user_staking_detail.amount,
                    user_staking_detail.reward_debt,
                    user_staking_detail.fixed_yield,
                    user_staking_detail.last_time_claimed,
                    user_staking_detail.start_time,
                    user_staking_detail.end_time
                );

            if pending_reward > 0 {
                let erc20_reward_dispatcher = IERC20Dispatcher { contract_address: _reward_token };
                // transfer reward
                erc20_reward_dispatcher.transfer(sender_addr, pending_reward);
            }
            let erc20_stake_dispatcher = IERC20Dispatcher { contract_address: _stake_token };
            // transfer stake
            erc20_stake_dispatcher.transfer(sender_addr, user_staking_detail.amount);
            // caculate reward debt
            let reward_debt = self
                .reward_debt(
                    user_staking_detail.amount,
                    user_staking_detail.fixed_yield,
                    user_staking_detail.last_time_claimed
                );
            // update user staking detail
            let current_time = get_block_timestamp();
            let new_user_staking_detail = UserStakingDetail {
                stake_id: user_staking_detail.stake_id,
                user_addr: user_staking_detail.user_addr,
                amount: 0,
                reward_debt: reward_debt,
                fixed_yield: user_staking_detail.fixed_yield,
                start_time: user_staking_detail.start_time,
                end_time: user_staking_detail.end_time,
                last_time_claimed: current_time,
                stake_token: user_staking_detail.stake_token,
                reward_token: user_staking_detail.reward_token,
            };
            // emit event
            let withdraw_event = WithdrawEvent {
                stake_id: _stake_id,
                user_addr: sender_addr,
                amount: user_staking_detail.amount,
                stake_token: _stake_token,
                reward_token: _reward_token,
            };
            self.stakings_details.write(_stake_id, new_user_staking_detail);
            self.emit(withdraw_event);
        }

        //view functions
        fn get_pool_info(
            self: @ContractState, _stake_token: ContractAddress, _reward_token: ContractAddress
        ) -> PoolInfo {
            let pool = self.pools.read((_stake_token, _reward_token));
            assert(
                pool.stake_token == _stake_token && pool.reward_token == _reward_token,
                Pramb_Cover_ERRs::ERROR_POOL_NOT_EXIST
            );
            return pool;
        }
        fn get_staking_option(
            self: @ContractState,
            _stake_token: ContractAddress,
            _reward_token: ContractAddress,
            _index_option: u64
        ) -> StakingOption {
            let staking_option = self
                .staking_options
                .read((_stake_token, _reward_token, _index_option));
            assert(staking_option.days > 0, Pramb_Cover_ERRs::ERROR_WRONG_STAKING_OPTIONS);
            return staking_option;
        }
        fn get_user_staking_detail(self: @ContractState, _stake_id: u128) -> UserStakingDetail {
            let user_staking_detail = self.stakings_details.read(_stake_id);
            assert(
                user_staking_detail.stake_id == _stake_id, Pramb_Cover_ERRs::ERROR_STAKE_ID_NOTFOUND
            );
            return user_staking_detail;
        }
        fn caculate_pending_reward(self: @ContractState, _stake_id: u128) -> u256 {
            let user_staking_detail = self.stakings_details.read(_stake_id);
            assert(
                user_staking_detail.stake_id == _stake_id, Pramb_Cover_ERRs::ERROR_STAKE_ID_NOTFOUND
            );
            let pending_reward = self
                .cal_pending_reward(
                    user_staking_detail.amount,
                    user_staking_detail.reward_debt,
                    user_staking_detail.fixed_yield,
                    user_staking_detail.last_time_claimed,
                    user_staking_detail.start_time,
                    user_staking_detail.end_time
                );
            return pending_reward;
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn cal_pending_reward(
            self: @ContractState,
            _amount: u256,
            _reward_debt: u256,
            _fixed_yield: u128,
            _last_time_claimed: u64,
            _start_time_stake: u64,
            _end_time_stake: u64
        ) -> u256 {
            let current_time = get_block_timestamp();
            let reward_per_year: u256 = _fixed_yield.into() * _amount / BASE_DENOMINATOR.into();
            let reward_per_second: u256 = reward_per_year / (365 * 24 * 60 * 60);

            // check
            if (current_time >= _end_time_stake) {
                let time_caculate_rewrard = _end_time_stake - _start_time_stake;
                return (reward_per_second * time_caculate_rewrard.into()) - _reward_debt;
            } else {
                let time_caculate_reward = if (_last_time_claimed == 0) {
                    current_time - _start_time_stake
                } else {
                    current_time - _last_time_claimed
                };
                return reward_per_second * time_caculate_reward.into();
            }
        }

        fn reward_debt(
            self: @ContractState, _amount: u256, _fixed_yield: u128, _last_time_claimed: u64
        ) -> u256 {
            let reward_per_year: u256 = _fixed_yield.into() * _amount / BASE_DENOMINATOR.into();
            let reward_per_second: u256 = reward_per_year / (365 * 24 * 60 * 60);
            if (_last_time_claimed == 0) {
                return 0;
            } else {
                return reward_per_second * _last_time_claimed.into();
            }
        }

        fn total_can_claim_reward(
            self: @ContractState,
            _amount: u256,
            _fixed_yield: u128,
            _start_time: u64,
            _end_time: u64
        ) -> u256 {
            let reward_per_year: u256 = _fixed_yield.into() * _amount / BASE_DENOMINATOR.into();
            let reward_per_second: u256 = reward_per_year / (365 * 24 * 60 * 60);
            let time_calculate_reward = _end_time - _start_time;
            return reward_per_second * time_calculate_reward.into();
        }
    }
}
