/// CampaignDonation contract implementation
#[starknet::contract]
pub mod CampaignDonation {
    use core::num::traits::Zero;
    use core::traits::Into;
    use fundable::interfaces::ICampaignDonation::ICampaignDonation;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::{
        ClassHash, ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
        get_contract_address,
    };
    use crate::base::errors::Errors::{
        CALLER_NOT_CAMPAIGN_OWNER, CAMPAIGN_CLOSED, CAMPAIGN_NOT_CLOSED, CAMPAIGN_REF_EMPTY, CAMPAIGN_REF_EXISTS,
        CANNOT_DENOTE_ZERO_AMOUNT, DOUBLE_WITHDRAWAL, INSUFFICIENT_ALLOWANCE, MORE_THAN_TARGET,
        TARGET_NOT_REACHED, TARGET_REACHED, WITHDRAWAL_FAILED, ZERO_ALLOWANCE, ZERO_AMOUNT,
        CAMPAIGN_WITHDRAWN, CAMPAIGN_HAS_DONATIONS, CAMPAIGN_NOT_FOUND, REFUND_ALREADY_CLAIMED,
        DONATION_NOT_FOUND,
    };
    use crate::base::types::{Campaigns, Donations};

    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;


    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        campaign_counts: u256,
        campaigns: Map<u256, Campaigns>, // (campaign_id, Campaigns)
        donations: Map<u256, Vec<Donations>>, // MAP((campaign_id, donation_id), donation)
        donation_counts: Map<u256, u256>,
        donation_count: u256,
        campaign_refs: Map<felt252, bool>, // All campaign ref to use for is_campaign_ref_exists
        campaign_closed: Map<u256, bool>, // Map campaign ids to closing boolean
        campaign_withdrawn: Map<u256, bool>, //Map campaign ids to whether they have been withdrawn
        donation_token: ContractAddress,
        refunds_claimed: Map<(u256, ContractAddress), bool>, // Map((campaign_id, donor), claimed)
        donations_by_donor: Map<(u256, ContractAddress), u256>, // Map((campaign_id, donor), total_donation)
    }


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Campaign: Campaign,
        Donation: Donation,
        CampaignWithdrawal: CampaignWithdrawal,
        CampaignUpdated: CampaignUpdated,
        CampaignCancelled: CampaignCancelled,
        CampaignRefunded: CampaignRefunded,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }


    #[derive(Drop, starknet::Event)]
    pub struct Campaign {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub campaign_reference: felt252,
        #[key]
        pub campaign_id: u256,
        #[key]
        pub target_amount: u256,
        #[key]
        pub timestamp: u64,
    }


    #[derive(Drop, starknet::Event)]
    pub struct Donation {
        #[key]
        pub donor: ContractAddress,
        #[key]
        pub campaign_id: u256,
        #[key]
        pub amount: u256,
        #[key]
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CampaignWithdrawal {
        #[key]
        pub owner: ContractAddress,
        #[key]
        pub campaign_id: u256,
        #[key]
        pub amount: u256,
        #[key]
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CampaignUpdated {
        #[key]
        pub campaign_id: u256,
        #[key]
        pub new_target: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CampaignCancelled {
        #[key]
        pub campaign_id: u256,
        #[key]
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct CampaignRefunded {
        #[key]
        pub campaign_id: u256,
        #[key]
        pub donor: ContractAddress,
        #[key]
        pub amount: u256,
        #[key]
        pub timestamp: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, token: ContractAddress) {
        self.ownable.initializer(owner);
        self.donation_token.write(token);
    }

    #[abi(embed_v0)]
    impl CampaignDonationImpl of ICampaignDonation<ContractState> {
        fn create_campaign(
            ref self: ContractState, campaign_ref: felt252, target_amount: u256,
        ) -> u256 {
            assert(campaign_ref != '', CAMPAIGN_REF_EMPTY);
            assert(!self.campaign_refs.read(campaign_ref), CAMPAIGN_REF_EXISTS);
            assert(target_amount > 0, ZERO_AMOUNT);
            let campaign_id: u256 = self.campaign_counts.read() + 1;
            let caller = get_caller_address();
            let timestamp = get_block_timestamp();
            let current_balance: u256 = 0;
            let withdrawn_amount: u256 = 0;
            let campaign = Campaigns {
                campaign_id,
                owner: caller,
                target_amount,
                current_balance,
                withdrawn_amount,
                campaign_reference: campaign_ref,
                is_closed: false,
                is_goal_reached: false,
                donation_token: self.donation_token.read(),
            };

            self.campaigns.write(campaign_id, campaign);
            self.campaign_counts.write(campaign_id);
            self.campaign_refs.write(campaign_ref, true);
            self
                .emit(
                    Event::Campaign(
                        Campaign {
                            owner: caller,
                            campaign_reference: campaign_ref,
                            campaign_id,
                            target_amount,
                            timestamp,
                        },
                    ),
                );

            campaign_id
        }

        fn donate_to_campaign(ref self: ContractState, campaign_id: u256, amount: u256) -> u256 {
            assert(amount > 0, CANNOT_DENOTE_ZERO_AMOUNT);
            let donor = get_caller_address();
            let mut campaign = self.get_campaign(campaign_id);
            let contract_address = get_contract_address();
            let timestamp = get_block_timestamp();
            let donation_token = self.donation_token.read();
            // cannot send more than target amount
            assert!(amount <= campaign.target_amount, "Error: More than Target");

            let donation_id = self.donation_count.read() + 1;

            // Ensure the campaign is still accepting donations
            assert(!campaign.is_goal_reached, TARGET_REACHED);

            // Prepare the ERC20 interface
            let token_dispatcher = IERC20Dispatcher { contract_address: donation_token };

            // Transfer funds to contract — requires prior approval
            token_dispatcher.transfer_from(donor, contract_address, amount);

            // Update campaign amount
            campaign.current_balance = campaign.current_balance + amount;

            // Update donor's total donation for this campaign
            let current_total = self.donations_by_donor.read((campaign_id, donor));
            self.donations_by_donor.write((campaign_id, donor), current_total + amount);

            // If goal reached, mark as closed
            if (campaign.current_balance >= campaign.target_amount) {
                campaign.is_goal_reached = true;
                campaign.is_closed = true;
            }

            self.campaigns.write(campaign_id, campaign);

            // Create donation record
            let donation = Donations { donation_id, donor, campaign_id, amount };

            // Properly append to the Vec using push
            self.donations.entry(campaign_id).push(donation);

            self.donation_count.write(donation_id);

            // Update the per-campaign donation count
            let campaign_donation_count = self.donation_counts.read(campaign_id);
            self.donation_counts.write(campaign_id, campaign_donation_count + 1);
            let timestamp = get_block_timestamp();
            // Emit donation event
            self.emit(Event::Donation(Donation { donor, campaign_id, amount, timestamp }));

            donation_id
        }


        fn withdraw_from_campaign(ref self: ContractState, campaign_id: u256) {
            let caller = get_caller_address();
            let mut campaign = self.campaigns.read(campaign_id);
            let campaign_owner = campaign.owner;
            assert(caller == campaign_owner, CALLER_NOT_CAMPAIGN_OWNER);
            campaign.is_goal_reached = true;

            let this_contract = get_contract_address();

            assert(campaign.is_closed, CAMPAIGN_NOT_CLOSED);

            assert(!self.campaign_withdrawn.read(campaign_id), DOUBLE_WITHDRAWAL);

            let donation_token = self.donation_token.read();

            let token = IERC20Dispatcher { contract_address: donation_token };

            let withdrawn_amount = campaign.current_balance;
            let transfer_from = token.transfer(campaign_owner, withdrawn_amount);

            campaign.withdrawn_amount = campaign.withdrawn_amount + withdrawn_amount;
            campaign.is_goal_reached = true;
            self.campaign_closed.write(campaign_id, true);
            self.campaigns.write(campaign_id, campaign);
            assert(transfer_from, WITHDRAWAL_FAILED);
            let timestamp = get_block_timestamp();
            // emit CampaignWithdrawal event
            self
                .emit(
                    Event::CampaignWithdrawal(
                        CampaignWithdrawal {
                            owner: caller, campaign_id, amount: withdrawn_amount, timestamp,
                        },
                    ),
                );
        }

        fn get_donation(self: @ContractState, campaign_id: u256, donation_id: u256) -> Donations {
            // Since donations are stored sequentially in the Vec, we need to find the index
            // The donation_id is global, so we need to iterate through the Vec to find it
            let vec_len = self.donations.entry(campaign_id).len();
            let mut i: u64 = 0;

            while i < vec_len {
                let donation = self.donations.entry(campaign_id).at(i).read();
                if donation.donation_id == donation_id {
                    return donation;
                }
                i += 1;
            }

            // Return empty donation if not found
            Donations {
                donation_id: 0, donor: contract_address_const::<0>(), campaign_id: 0, amount: 0,
            }
        }

        fn get_campaigns(self: @ContractState) -> Array<Campaigns> {
            let mut campaigns = ArrayTrait::new();
            let campaigns_count = self.campaign_counts.read();

            // Iterate through all campaign IDs (1 to campaigns_count)
            let mut i: u256 = 1;
            while i <= campaigns_count {
                let campaign = self.campaigns.read(i);
                campaigns.append(campaign);
                i += 1;
            }

            campaigns
        }

        fn get_campaign_donations(self: @ContractState, campaign_id: u256) -> Array<Donations> {
            let mut donations = ArrayTrait::new();

            // Get the length of the Vec for this campaign
            let vec_len = self.donations.entry(campaign_id).len();

            // Iterate through all donations in the Vec
            let mut i: u64 = 0;
            while i < vec_len {
                let donation = self.donations.entry(campaign_id).at(i).read();
                donations.append(donation);
                i += 1;
            }

            donations
        }

        fn get_campaign(self: @ContractState, campaign_id: u256) -> Campaigns {
            let campaign: Campaigns = self.campaigns.read(campaign_id);
            campaign
        }

        fn update_campaign_target(ref self: ContractState, campaign_id: u256, new_target: u256) {
            let caller = get_caller_address();
            assert(campaign_id > 0, CAMPAIGN_NOT_FOUND);
            assert(campaign_id <= self.campaign_counts.read(), CAMPAIGN_NOT_FOUND);
            let mut campaign = self.get_campaign(campaign_id);
            assert(caller == campaign.owner, CALLER_NOT_CAMPAIGN_OWNER);
            assert(campaign.current_balance == 0, CAMPAIGN_HAS_DONATIONS);
            assert(new_target > 0, ZERO_AMOUNT);
            campaign.target_amount = new_target;
            self.campaigns.write(campaign_id, campaign);
            self
                .emit(
                    Event::CampaignUpdated(
                        CampaignUpdated { 
                            campaign_id, new_target 
                        }
                    )
                );
        }

        fn cancel_campaign(ref self: ContractState, campaign_id: u256) {
            let caller = get_caller_address();
            assert(campaign_id > 0, CAMPAIGN_NOT_FOUND);
            assert(campaign_id <= self.campaign_counts.read(), CAMPAIGN_NOT_FOUND);
            let mut campaign = self.get_campaign(campaign_id);
            assert(caller == campaign.owner, CALLER_NOT_CAMPAIGN_OWNER);
            assert(!campaign.is_closed, CAMPAIGN_CLOSED);
            assert(!campaign.is_goal_reached, TARGET_REACHED);
            assert(campaign.withdrawn_amount == 0, CAMPAIGN_WITHDRAWN);
            let timestamp = get_block_timestamp();
            campaign.is_closed = true;
            self.campaigns.write(campaign_id, campaign);
            self
                .emit(
                    Event::CampaignCancelled(
                        CampaignCancelled { 
                            campaign_id, 
                            timestamp 
                        }
                    )
                );
        }

        fn claim_refund(ref self: ContractState, campaign_id: u256) {
            let caller = get_caller_address();
            assert(campaign_id > 0, CAMPAIGN_NOT_FOUND);
            assert(campaign_id <= self.campaign_counts.read(), CAMPAIGN_NOT_FOUND);
            let mut campaign = self.get_campaign(campaign_id);
            
            // Check if campaign is cancelled
            assert(campaign.is_closed, CAMPAIGN_CLOSED);
            assert(campaign.withdrawn_amount == 0, CAMPAIGN_WITHDRAWN);
            
            // Check if caller has already claimed refund
            assert(!self.refunds_claimed.read((campaign_id, caller)), REFUND_ALREADY_CLAIMED);
            
            // Get total donation amount directly from mapping
            let total_donation = self.donations_by_donor.read((campaign_id, caller));
            
            // Ensure caller has donated
            assert(total_donation > 0, DONATION_NOT_FOUND);
            
            // Transfer tokens back to donor
            let donation_token = self.donation_token.read();
            let token = IERC20Dispatcher { contract_address: donation_token };
            let transfer_success = token.transfer(caller, total_donation);
            assert(transfer_success, WITHDRAWAL_FAILED);
            
            // Mark refund as claimed
            self.refunds_claimed.write((campaign_id, caller), true);
            
            // Emit event
            let timestamp = get_block_timestamp();
            self.emit(
                Event::CampaignRefunded(
                    CampaignRefunded {
                        campaign_id,
                        donor: caller,
                        amount: total_donation,
                        timestamp
                    }
                )
            );
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn get_asset_address(self: @ContractState, token_name: felt252) -> ContractAddress {
            let mut token_address: ContractAddress = contract_address_const::<0>();
            if token_name == 'USDC' || token_name == 'usdc' {
                token_address =
                    contract_address_const::<
                        0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8,
                    >();
            }
            if token_name == 'STRK' || token_name == 'strk' {
                token_address =
                    contract_address_const::<
                        0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
                    >();
            }
            if token_name == 'ETH' || token_name == 'eth' {
                token_address =
                    contract_address_const::<
                        0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7,
                    >();
            }
            if token_name == 'USDT' || token_name == 'usdt' {
                token_address =
                    contract_address_const::<
                        0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8,
                    >();
            }

            token_address
        }
    }
}
