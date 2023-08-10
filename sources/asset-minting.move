module mirror_world_sui_asset_minting::asset_minting {
    use std::ascii;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::vector;

    use nft_protocol::attributes::{Self, Attributes};
    use nft_protocol::collection::{Self, Collection};
    use nft_protocol::creators;
    use nft_protocol::display_info;
    use nft_protocol::royalty;
    use nft_protocol::royalty_strategy_bps;
    use ob_permissions::witness::Self as ob_permissions_witness;
    use ob_request::request::{Policy, PolicyCap, WithNft};
    use ob_request::transfer_request::Self as ob_transfer_request;
    use ob_request::withdraw_request::{Self as ob_withdraw_request, WITHDRAW_REQ};
    use ob_utils::utils::Self;
    use sui::coin::{Self, Coin};
    use sui::display;
    use sui::ed25519;
    use sui::event::emit;
    use sui::hash;
    use sui::object::{Self, ID, UID};
    use sui::package::Publisher;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url::{Self, Url};

    const VERSION: u64 = 2;

    // Erros
    const ENotAdmin: u64 = 1001;
    const EWrongVersion: u64 = 1002;
    const ENotUpgrade: u64 = 1003;
    const EInvalidAmount: u64 = 1004;
    const EMissingSalt: u64 = 1005;
    const EMissingSignature: u64 = 1006;
    const EInvalidSigner: u64 = 1007;
    const EEmpty: u64 = 1008;
    const EMintDisbale: u64 = 1009;
    const EInvalidCollection: u64 = 1010;
    const ESupplyExceeded: u64 = 1011;
    const EInvalidMethod: u64 = 1012;
    const EMintPaymentNotFound: u64 = 1013;
    const EMintPaymentReceiverNotFound: u64 = 1014;
    const EMintCommissionPaymentNotFound: u64 = 1015;
    const EMintCommissionPaymentReceiverNotFound: u64 = 1016;
    const EInvalidCommsionAmount: u64 = 1017;
    const EInvalidSupply: u64 = 1018;

    struct AdminCap has key, store {
        id: UID
    }

    struct MintCap has key, store {
        id: UID
    }

    struct CollectionConfig<phantom FT> has key {
        id: UID,
        signing_authority_required: bool,
        signing_authority_public_key: vector<u8>,
        max_supply: Option<u64>,
        current_supply: u64,
        mint_enable: bool,
        mint_payment_enable: bool,
        mint_payment: Option<u64>,
        mint_payment_receiver: Option<address>,
        mint_commission_enable: bool,
        mint_commission_payment: Option<u64>,
        mint_commission_receiver: Option<address>,
        collection_id: ID,
        collection_transfer_policy: ID,
        object_owner: ID
    }

    struct VersionConfig has key, store {
        id: UID,
        version: u64,
        object_owner: ID
    }

    /// Can be used for authorization of other actions post-creation. It is
    /// vital that this struct is not freely given to any contract, because it
    /// serves as an auth token.
    struct Witness has drop {}

    struct ASSET_MINTING has drop {}

    struct NFTData has key, store {
        id: UID,
        name: String,
        description: String,
        url: Url,
        attributes: Attributes,
        collection_id: ID
    }

    // Events

    struct CreateCollectionEvent has copy, drop {
        signing_authority_required: bool,
        signing_authority_public_key: vector<u8>,
        max_supply: Option<u64>,
        mint_enable: bool,
        mint_payment_enable: bool,
        mint_payment: Option<u64>,
        mint_payment_receiver: Option<address>,
        mint_commission_enable: bool,
        mint_commission_payment: Option<u64>,
        mint_commission_receiver: Option<address>,
        collection_id: ID,
        collection_config_id: ID,
        transfer_policy_id: ID,
        transfer_policy_cap_id: ID
    }

    struct UpdateCollectionConfigEvent has copy, drop {
        signing_authority_required: bool,
        signing_authority_public_key: vector<u8>,
        max_supply: Option<u64>,
        mint_enable: bool,
        mint_payment_enable: bool,
        mint_payment: Option<u64>,
        mint_payment_receiver: Option<address>,
        mint_commission_enable: bool,
        mint_commission_payment: Option<u64>,
        mint_commission_receiver: Option<address>,
        updated_signing_authority_required: bool,
        updated_signing_authority_public_key: vector<u8>,
        updated_max_supply: Option<u64>,
        updated_mint_enable: bool,
        updated_mint_payment_enable: bool,
        updated_mint_payment: Option<u64>,
        updated_mint_payment_receiver: Option<address>,
        updated_mint_commission_enable: bool,
        updated_mint_commission_payment: Option<u64>,
        updated_mint_commission_receiver: Option<address>,
        collection_id: ID,
        collection_config_id: ID
    }

    struct MintNftEvent has copy, drop {
        nft_id: ID,
        nft_owner: ID,
        collection_id: ID,
        with_payment: bool,
        with_commission: bool,
        payment_coin_id: Option<ID>,
        commission_payment_coin_id: Option<ID>
    }


    // Init
    fun init(witness: ASSET_MINTING, ctx: &mut TxContext) {
        let adminCap: AdminCap = AdminCap {
            id: object::new(ctx)
        };

        let versionConfig: VersionConfig = VersionConfig {
            id: object::new(ctx),
            version: VERSION,
            object_owner: object::id(&adminCap)
        };

        let publisher = sui::package::claim(witness, ctx);

        let display = display::new<NFTData>(&publisher, ctx);
        display::add(&mut display, string::utf8(b"name"), string::utf8(b"{name}"));
        display::add(&mut display, string::utf8(b"description"), string::utf8(b"{description}"));
        display::add(&mut display, string::utf8(b"image_url"), string::utf8(b"{url}"));
        display::add(&mut display, string::utf8(b"attributes"), string::utf8(b"{attributes}"));
        display::add(&mut display, string::utf8(b"collection_id"), string::utf8(b"{collection_id}"));
        display::update_version(&mut display);
        transfer::public_transfer(display, tx_context::sender(ctx));

        let (policy, policy_cap): (Policy<WithNft<NFTData, WITHDRAW_REQ>>, PolicyCap) = ob_withdraw_request::init_policy<NFTData>(
            &publisher,
            ctx
        );

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(adminCap, tx_context::sender(ctx));

        transfer::public_transfer(policy_cap, tx_context::sender(ctx));
        transfer::public_share_object(policy);

        transfer::public_share_object(versionConfig);
    }

    public entry fun migrate_version_config(
        versionConfig: &mut VersionConfig,
        adminCap: &AdminCap,
        _ctx: &mut TxContext
    ) {
        assert!(versionConfig.object_owner == object::id(adminCap), ENotAdmin);
        assert!(versionConfig.version < VERSION, ENotUpgrade);
        versionConfig.version = VERSION;
    }

    public entry fun create_collection<FT>(
        versionConfig: &VersionConfig,
        publisher: &Publisher,
        adminCap: &AdminCap,
        signingAuthorityRequired: bool,
        signingAuthorityPublicKey: vector<u8>,
        maxSupply: Option<u64>,
        mintPaymentEnable: bool,
        mintPayment: Option<u64>,
        mintPaymentReceiver: Option<address>,
        mintCommissionEnable: bool,
        mintCommissionPayment: Option<u64>,
        mintCommissionReceiver: Option<address>,
        collectionName: vector<u8>,
        collectionDiscription: vector<u8>,
        creatorsList: vector<address>,
        creatorsShareList: vector<u16>,
        royalty: Option<u16>,
        ctx: &mut TxContext
    ) {
        assert!(versionConfig.version == VERSION, EWrongVersion);
        assert!(versionConfig.object_owner == object::id(adminCap), ENotAdmin);

        let dw = ob_permissions_witness::from_publisher<NFTData>(publisher);

        let collection: Collection<NFTData> = collection::create(dw, ctx);

        // Transfer Policy
        let (transfer_policy, transfer_policy_cap) = ob_transfer_request::init_policy<NFTData>(publisher, ctx);


        collection::add_domain(
            dw,
            &mut collection,
            display_info::new(
                string::utf8(collectionName),
                string::utf8(collectionDiscription),
            )
        );

        if (!vector::is_empty(&creatorsList)) {
            // Creators domain
            collection::add_domain(
                dw,
                &mut collection,
                creators::new(utils::vec_set_from_vec(&creatorsList)),
            );

            // Rolity Share
            if (!vector::is_empty(&creatorsShareList) && option::is_some(&royalty)) {
                let shares = utils::from_vec_to_map(creatorsList, creatorsShareList);

                royalty_strategy_bps::create_domain_and_add_strategy(
                    dw, &mut collection, royalty::from_shares(shares, ctx), *option::borrow(&royalty), ctx,
                );

                royalty_strategy_bps::enforce(&mut transfer_policy, &transfer_policy_cap);
            }
        };

        if (mintPaymentEnable) {
            assert!(option::is_some(&mintPayment), EMintPaymentNotFound);
            assert!(option::is_some(&mintPaymentReceiver), EMintPaymentReceiverNotFound);

            if (mintCommissionEnable) {
                assert!(option::is_some(&mintCommissionPayment), EMintCommissionPaymentNotFound);
                assert!(option::is_some(&mintCommissionReceiver), EMintCommissionPaymentReceiverNotFound);

                assert!(
                    *option::borrow(&mintPayment) > *option::borrow(&mintCommissionPayment),
                    EInvalidCommsionAmount
                );
            }
        };

        let collectionConfig = CollectionConfig<FT> {
            id: object::new(ctx),
            signing_authority_public_key: signingAuthorityPublicKey,
            signing_authority_required: signingAuthorityRequired,
            max_supply: maxSupply,
            current_supply: 0,
            mint_enable: true,
            mint_payment_enable: mintPaymentEnable,
            mint_payment: mintPayment,
            mint_payment_receiver: mintPaymentReceiver,
            mint_commission_enable: mintCommissionEnable,
            mint_commission_payment: mintCommissionPayment,
            mint_commission_receiver: mintCommissionReceiver,
            collection_id: object::id(&collection),
            collection_transfer_policy: object::id(&transfer_policy),
            object_owner: versionConfig.object_owner
        };

        let createCollectionEvent: CreateCollectionEvent = CreateCollectionEvent {
            signing_authority_public_key: signingAuthorityPublicKey,
            signing_authority_required: signingAuthorityRequired,
            max_supply: maxSupply,
            mint_enable: true,
            mint_payment_enable: mintPaymentEnable,
            mint_payment: mintPayment,
            mint_payment_receiver: mintPaymentReceiver,
            mint_commission_enable: mintCommissionEnable,
            mint_commission_payment: mintCommissionPayment,
            mint_commission_receiver: mintCommissionReceiver,
            collection_id: object::id(&collection),
            collection_config_id: object::id(&collectionConfig),
            transfer_policy_id: object::id(&transfer_policy),
            transfer_policy_cap_id: object::id(&transfer_policy_cap)
        };

        emit(createCollectionEvent);

        transfer::public_share_object(collection);
        transfer::share_object(collectionConfig);
        transfer::public_share_object(transfer_policy);
        transfer::public_transfer(transfer_policy_cap, tx_context::sender(ctx));
    }

    public entry fun update_collection_config<FT>(
        versionConfig: &VersionConfig,
        adminCap: &AdminCap,
        collectionConfig: &mut CollectionConfig<FT>,
        signingAuthorityRequired: bool,
        signingAuthorityPublicKey: vector<u8>,
        maxSupply: Option<u64>,
        mintPaymentEnable: bool,
        mintPayment: Option<u64>,
        mintPaymentReceiver: Option<address>,
        mintCommissionEnable: bool,
        mintCommissionPayment: Option<u64>,
        mintCommissionReceiver: Option<address>,
        mintEnable: bool,
        _ctx: &mut TxContext
    ) {
        assert!(versionConfig.version == VERSION, EWrongVersion);
        assert!(versionConfig.object_owner == object::id(adminCap), ENotAdmin);
        assert!(collectionConfig.object_owner == object::id(adminCap), ENotAdmin);

        let updateCollectionConfigEvent: UpdateCollectionConfigEvent = UpdateCollectionConfigEvent {
            signing_authority_required: collectionConfig.signing_authority_required,
            signing_authority_public_key: collectionConfig.signing_authority_public_key,
            mint_enable: collectionConfig.mint_enable,
            max_supply: collectionConfig.max_supply,
            mint_payment_enable: collectionConfig.mint_payment_enable,
            mint_payment: collectionConfig.mint_payment,
            mint_payment_receiver: collectionConfig.mint_payment_receiver,
            mint_commission_enable: collectionConfig.mint_commission_enable,
            mint_commission_payment: collectionConfig.mint_commission_payment,
            mint_commission_receiver: collectionConfig.mint_commission_receiver,
            updated_signing_authority_required: signingAuthorityRequired,
            updated_signing_authority_public_key: signingAuthorityPublicKey,
            updated_mint_enable: mintEnable,
            updated_max_supply: maxSupply,
            updated_mint_payment_enable: mintPaymentEnable,
            updated_mint_payment: mintPayment,
            updated_mint_payment_receiver: mintPaymentReceiver,
            updated_mint_commission_enable: mintCommissionEnable,
            updated_mint_commission_payment: mintCommissionPayment,
            updated_mint_commission_receiver: mintCommissionReceiver,
            collection_id: collectionConfig.collection_id,
            collection_config_id: object::id(collectionConfig)
        };


        if (mintPaymentEnable) {
            assert!(option::is_some(&mintPayment), EMintPaymentNotFound);
            assert!(option::is_some(&mintPaymentReceiver), EMintPaymentReceiverNotFound);

            if (mintCommissionEnable) {
                assert!(option::is_some(&mintCommissionPayment), EMintCommissionPaymentNotFound);
                assert!(option::is_some(&mintCommissionReceiver), EMintCommissionPaymentReceiverNotFound);

                assert!(
                    *option::borrow(&mintPayment) > *option::borrow(&mintCommissionPayment),
                    EInvalidCommsionAmount
                );
            }
        };

        if (option::is_some(&maxSupply)) {
            assert!(*option::borrow(&maxSupply) >= collectionConfig.current_supply, EInvalidSupply);
        };

        collectionConfig.signing_authority_required = signingAuthorityRequired;
        collectionConfig.signing_authority_public_key = signingAuthorityPublicKey;
        collectionConfig.mint_enable = mintEnable;
        collectionConfig.max_supply = maxSupply;
        collectionConfig.mint_payment_enable = mintPaymentEnable;
        collectionConfig.mint_payment = mintPayment;
        collectionConfig.mint_payment_receiver = mintPaymentReceiver;
        collectionConfig.mint_commission_enable = mintCommissionEnable;
        collectionConfig.mint_commission_payment = mintCommissionPayment;
        collectionConfig.mint_commission_receiver = mintCommissionReceiver;

        emit(updateCollectionConfigEvent);
    }

    public entry fun mint_nft<FT>(
        versionConfig: &VersionConfig,
        adminCap: &AdminCap,
        collectionConfig: &mut CollectionConfig<FT>,
        collection: &Collection<NFTData>,
        nftReceiverAddress: address,
        nftName: vector<u8>,
        nftDescription: vector<u8>,
        nftUrl: vector<u8>,
        attribute_keys: vector<ascii::String>,
        attribute_values: vector<ascii::String>,
        salt: Option<vector<u8>>,
        signature: Option<vector<u8>>,
        ctx: &mut TxContext
    ) {
        assert!(versionConfig.version == VERSION, EWrongVersion);
        assert!(versionConfig.object_owner == object::id(adminCap), ENotAdmin);
        assert!(collectionConfig.object_owner == object::id(adminCap), ENotAdmin);
        assert!(collectionConfig.collection_id == object::id(collection), EInvalidCollection);
        assert!(collectionConfig.mint_enable, EMintDisbale);

        if (option::is_some(&collectionConfig.max_supply)) {
            assert!(
                collectionConfig.current_supply + 1 <= *option::borrow(&collectionConfig.max_supply),
                ESupplyExceeded
            );
        };

        assert!(!collectionConfig.mint_payment_enable, EInvalidMethod);

        if (collectionConfig.signing_authority_required) {
            assert!(option::is_some(&salt), EMissingSalt);
            assert!(option::is_some(&signature), EMissingSignature);

            let hashed_msg = hash::keccak256(&option::extract(&mut salt));
            let is_valid = ed25519::ed25519_verify(
                &option::extract(&mut signature),
                &collectionConfig.signing_authority_public_key,
                &hashed_msg
            );

            assert!(is_valid == true, EInvalidSigner);
        };

        let nft: NFTData = NFTData {
            id: object::new(ctx),
            name: string::utf8(nftName),
            description: string::utf8(nftDescription),
            url: url::new_unsafe_from_bytes(nftUrl),
            attributes: attributes::from_vec(attribute_keys, attribute_values),
            collection_id: object::id(collection)
        };

        collectionConfig.current_supply = collectionConfig.current_supply + 1;

        let mintNftEvent: MintNftEvent = MintNftEvent {
            collection_id: object::id(collection),
            nft_id: object::id(&nft),
            nft_owner: object::id_from_address(nftReceiverAddress),
            with_payment: false,
            with_commission: false,
            payment_coin_id: option::none<ID>(),
            commission_payment_coin_id: option::none<ID>()
        };

        emit(mintNftEvent);

        transfer::public_transfer(nft, nftReceiverAddress);
    }

    public entry fun mint_nft_with_payment<FT>(
        versionConfig: &VersionConfig,
        collectionConfig: &mut CollectionConfig<FT>,
        collection: &Collection<NFTData>,
        nftReceiverAddress: address,
        nftName: vector<u8>,
        nftDescription: vector<u8>,
        nftUrl: vector<u8>,
        attribute_keys: vector<ascii::String>,
        attribute_values: vector<ascii::String>,
        salt: Option<vector<u8>>,
        signature: Option<vector<u8>>,
        wallet: &mut Coin<FT>,
        ctx: &mut TxContext
    ) {
        assert!(versionConfig.version == VERSION, EWrongVersion);
        assert!(collectionConfig.collection_id == object::id(collection), EInvalidCollection);
        assert!(collectionConfig.mint_enable, EMintDisbale);

        if (option::is_some(&collectionConfig.max_supply)) {
            assert!(
                collectionConfig.current_supply + 1 <= *option::borrow(&collectionConfig.max_supply),
                ESupplyExceeded
            );
        };

        assert!(collectionConfig.mint_payment_enable, EInvalidMethod);

        if (collectionConfig.signing_authority_required) {
            assert!(option::is_some(&salt), EMissingSalt);
            assert!(option::is_some(&signature), EMissingSignature);

            let hashed_msg = hash::keccak256(&option::extract(&mut salt));
            let is_valid = ed25519::ed25519_verify(
                &option::extract(&mut signature),
                &collectionConfig.signing_authority_public_key,
                &hashed_msg
            );

            assert!(is_valid == true, EInvalidSigner);
        };

        // Payment

        assert!(option::is_some(&collectionConfig.mint_payment), EMintPaymentNotFound);
        assert!(option::is_some(&collectionConfig.mint_payment_receiver), EMintPaymentReceiverNotFound);

        assert!(coin::value(wallet) >= *option::borrow(&collectionConfig.mint_payment), EInvalidAmount);

        let paymentCoin: Coin<FT> = coin::split(wallet, *option::borrow(&collectionConfig.mint_payment), ctx);

        let withCommission: bool = false;
        let commissionPaymentCoinId: Option<ID> = option::none<ID>();
        let paymentCoinId: Option<ID> = option::some(object::id(&paymentCoin));

        if (collectionConfig.mint_commission_enable) {
            assert!(option::is_some(&collectionConfig.mint_commission_payment), EMintCommissionPaymentNotFound);
            assert!(
                option::is_some(&collectionConfig.mint_commission_receiver),
                EMintCommissionPaymentReceiverNotFound
            );

            assert!(
                *option::borrow(&collectionConfig.mint_commission_payment) < *option::borrow(
                    &collectionConfig.mint_payment
                ),
                EInvalidCommsionAmount
            );

            let commissionPaymentCoin: Coin<FT> = coin::split(
                &mut paymentCoin,
                *option::borrow(&collectionConfig.mint_commission_payment),
                ctx
            );

            withCommission = true;
            commissionPaymentCoinId = option::some(object::id(&commissionPaymentCoin));

            transfer::public_transfer(
                commissionPaymentCoin,
                *option::borrow(&collectionConfig.mint_commission_receiver)
            );
        };

        transfer::public_transfer(paymentCoin, *option::borrow(&collectionConfig.mint_payment_receiver));

        let nft: NFTData = NFTData {
            id: object::new(ctx),
            name: string::utf8(nftName),
            description: string::utf8(nftDescription),
            url: url::new_unsafe_from_bytes(nftUrl),
            attributes: attributes::from_vec(attribute_keys, attribute_values),
            collection_id: object::id(collection)
        };

        collectionConfig.current_supply = collectionConfig.current_supply + 1;

        let mintNftEvent: MintNftEvent = MintNftEvent {
            collection_id: object::id(collection),
            nft_id: object::id(&nft),
            nft_owner: object::id_from_address(nftReceiverAddress),
            with_payment: true,
            with_commission: withCommission,
            payment_coin_id: paymentCoinId,
            commission_payment_coin_id: commissionPaymentCoinId
        };

        emit(mintNftEvent);

        transfer::public_transfer(nft, nftReceiverAddress);
    }

    public entry fun mint_nft_with_payment_v2<FT>(
        versionConfig: &VersionConfig,
        collectionConfig: &mut CollectionConfig<FT>,
        collection: &Collection<NFTData>,
        nftReceiverAddress: address,
        nftName: vector<u8>,
        nftDescription: vector<u8>,
        nftUrl: vector<u8>,
        attribute_keys: vector<ascii::String>,
        attribute_values: vector<ascii::String>,
        salt: Option<vector<u8>>,
        signature: Option<vector<u8>>,
        wallet: Coin<FT>,
        ctx: &mut TxContext
    ) {
        assert!(versionConfig.version == VERSION, EWrongVersion);
        assert!(collectionConfig.collection_id == object::id(collection), EInvalidCollection);
        assert!(collectionConfig.mint_enable, EMintDisbale);

        if (option::is_some(&collectionConfig.max_supply)) {
            assert!(
                collectionConfig.current_supply + 1 <= *option::borrow(&collectionConfig.max_supply),
                ESupplyExceeded
            );
        };

        assert!(collectionConfig.mint_payment_enable, EInvalidMethod);

        if (collectionConfig.signing_authority_required) {
            assert!(option::is_some(&salt), EMissingSalt);
            assert!(option::is_some(&signature), EMissingSignature);

            let hashed_msg = hash::keccak256(&option::extract(&mut salt));
            let is_valid = ed25519::ed25519_verify(
                &option::extract(&mut signature),
                &collectionConfig.signing_authority_public_key,
                &hashed_msg
            );

            assert!(is_valid == true, EInvalidSigner);
        };

        // Payment

        assert!(option::is_some(&collectionConfig.mint_payment), EMintPaymentNotFound);
        assert!(option::is_some(&collectionConfig.mint_payment_receiver), EMintPaymentReceiverNotFound);

        assert!(coin::value(&wallet) >= *option::borrow(&collectionConfig.mint_payment), EInvalidAmount);

        let paymentCoin: Coin<FT> = coin::split(&mut wallet, *option::borrow(&collectionConfig.mint_payment), ctx);

        let withCommission: bool = false;
        let commissionPaymentCoinId: Option<ID> = option::none<ID>();
        let paymentCoinId: Option<ID> = option::some(object::id(&paymentCoin));

        if (collectionConfig.mint_commission_enable) {
            assert!(option::is_some(&collectionConfig.mint_commission_payment), EMintCommissionPaymentNotFound);
            assert!(
                option::is_some(&collectionConfig.mint_commission_receiver),
                EMintCommissionPaymentReceiverNotFound
            );

            assert!(
                *option::borrow(&collectionConfig.mint_commission_payment) < *option::borrow(
                    &collectionConfig.mint_payment
                ),
                EInvalidCommsionAmount
            );

            let commissionPaymentCoin: Coin<FT> = coin::split(
                &mut paymentCoin,
                *option::borrow(&collectionConfig.mint_commission_payment),
                ctx
            );

            withCommission = true;
            commissionPaymentCoinId = option::some(object::id(&commissionPaymentCoin));

            transfer::public_transfer(
                commissionPaymentCoin,
                *option::borrow(&collectionConfig.mint_commission_receiver)
            );
        };

        transfer::public_transfer(paymentCoin, *option::borrow(&collectionConfig.mint_payment_receiver));

        let nft: NFTData = NFTData {
            id: object::new(ctx),
            name: string::utf8(nftName),
            description: string::utf8(nftDescription),
            url: url::new_unsafe_from_bytes(nftUrl),
            attributes: attributes::from_vec(attribute_keys, attribute_values),
            collection_id: object::id(collection)
        };

        collectionConfig.current_supply = collectionConfig.current_supply + 1;

        let mintNftEvent: MintNftEvent = MintNftEvent {
            collection_id: object::id(collection),
            nft_id: object::id(&nft),
            nft_owner: object::id_from_address(nftReceiverAddress),
            with_payment: true,
            with_commission: withCommission,
            payment_coin_id: paymentCoinId,
            commission_payment_coin_id: commissionPaymentCoinId
        };

        emit(mintNftEvent);

        transfer::public_transfer(nft, nftReceiverAddress);
        transfer::public_transfer(wallet, tx_context::sender(ctx));
    }
}