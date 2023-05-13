module mirror_world_sui_asset_minting::asset_minting {
    use std::ascii;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::vector;

    use nft_protocol::attributes::{Self, Attributes};
    use nft_protocol::collection::{Self, Collection};
    use nft_protocol::creators;
    use nft_protocol::display_info;
    use nft_protocol::mint_cap::{Self, MintCap};
    use nft_protocol::mint_event;

    use ob_permissions::witness;

    use sui::display;
    use sui::ed25519;
    use sui::hash;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url::{Self, Url};
    use sui::vec_set::{Self, VecSet};

    struct SuperAdminCap has key, store {
        id: UID
    }

    struct CollectionCreateAuthorityCap has key, store {
        id: UID
    }

    // Collection Status
    const CS_ACTIVE: u8 = 1;
    const CS_DEACTIVE: u8 = 2;

    // ERROR
    const ER_COLLECTION_IS_NOT_ACTIVE: u64 = 30001;
    const ER_MISSING_SALT: u64 = 30002;
    const ER_MISSING_SIGNATURE: u64 = 30003;
    const ER_INVALID_SIGNER: u64 = 30004;
    const ER_INVALID_UPDATE_AUTHORITY: u64 = 30005;

    struct CollectionConfig has key {
        id: UID,
        status: u8,
        signingAuthorityRequired: bool,
        signingAuthorityPublicKey: vector<u8>,
        updateAuthority: address,
        collectionId: address
    }

    struct SigningAuthorityConfig has key {
        id: UID,
        publicKey: vector<u8>,
        updateAuthority: address
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
        attributes: Attributes
    }

    // Init
    fun init(witness: ASSET_MINTING, ctx: &mut TxContext) {
        let superAdminCap: SuperAdminCap = SuperAdminCap {
            id: object::new(ctx)
        };

        let publisher = sui::package::claim(witness, ctx);

        let display = display::new<NFTData>(&publisher, ctx);
        display::add(&mut display, string::utf8(b"name"), string::utf8(b"{name}"));
        display::add(&mut display, string::utf8(b"description"), string::utf8(b"{description}"));
        display::add(&mut display, string::utf8(b"image_url"), string::utf8(b"{url}"));
        display::add(&mut display, string::utf8(b"attributes"), string::utf8(b"{attributes}"));
        display::update_version(&mut display);
        transfer::public_transfer(display, tx_context::sender(ctx));

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::transfer(superAdminCap, tx_context::sender(ctx));
    }

    public entry fun create_collection_create_authority_cap(
        _superAdminCap: &SuperAdminCap,
        collectionCreateAuthorityAddress: address,
        ctx: &mut TxContext
    ) {
        let collectionCreateAuthorityCap: CollectionCreateAuthorityCap = CollectionCreateAuthorityCap {
            id: object::new(ctx)
        };

        transfer::transfer(collectionCreateAuthorityCap, collectionCreateAuthorityAddress);
    }

    public entry fun create_collection(
        _collectionCreateAuthorityCap: &CollectionCreateAuthorityCap,
        signingAuthorityPublicKey: vector<u8>,
        updateAuthorityAddress: address,
        isSigningAuthorityRequired: bool,
        supply: Option<u64>,
        nftMintCapOwnerAddress: address,
        collectionName: vector<u8>,
        collectionDiscription: vector<u8>,
        creatorsList: vector<address>,
        ctx: &mut TxContext
    ) {
        let delegated_witness = witness::from_witness(Witness {});

        let witness = Witness {};

        let collection: Collection<NFTData> = collection::create(delegated_witness, ctx);


        let mint_cap: MintCap<NFTData> = mint_cap::new<Witness, NFTData>(
            &witness,
            object::id(&collection),
            supply,
            ctx
        );

        // let (collection, mint_cap) = collection::create_with_mint_cap<Witness, NFTData>(
        //     &witness, supply, ctx
        // );

        let collectionConfig: CollectionConfig = CollectionConfig {
            id: object::new(ctx),
            status: CS_ACTIVE,
            signingAuthorityPublicKey: signingAuthorityPublicKey,
            updateAuthority: updateAuthorityAddress,
            signingAuthorityRequired: isSigningAuthorityRequired,
            collectionId: object::id_address(&collection)
        };

        collection::add_domain(
            delegated_witness,
            &mut collection,
            display_info::new(
                string::utf8(collectionName),
                string::utf8(collectionDiscription),
            )
        );

        if (!vector::is_empty(&creatorsList)) {
            let crestorL: VecSet<address> = vec_set::empty<address>();

            let cs = vector::length(&creatorsList);

            if (cs == 1) {
                crestorL = vec_set::singleton(*vector::borrow(&creatorsList, 0));
            } else {
                let i = 0;
                while (i < cs) {
                    vec_set::insert(&mut crestorL, *vector::borrow(&creatorsList, i));

                    i = i + 1;
                }
            };

            // Creators domain
            collection::add_domain(
                delegated_witness,
                &mut collection,
                creators::new(crestorL),
            );
        };

        transfer::public_transfer(mint_cap, nftMintCapOwnerAddress);
        transfer::public_share_object(collection);
        transfer::share_object(collectionConfig);
    }

    public entry fun mint_nft(
        mint_cap: &mut MintCap<NFTData>,
        collectionConfig: &CollectionConfig,
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
        assert!(collectionConfig.status == CS_ACTIVE, ER_COLLECTION_IS_NOT_ACTIVE);

        if (collectionConfig.signingAuthorityRequired) {
            assert!(option::is_some(&salt), ER_MISSING_SALT);
            assert!(option::is_some(&signature), ER_MISSING_SIGNATURE);

            let hashed_msg = hash::keccak256(&option::extract(&mut salt));
            let is_valid = ed25519::ed25519_verify(
                &option::extract(&mut signature),
                &collectionConfig.signingAuthorityPublicKey,
                &hashed_msg
            );

            assert!(is_valid == true, ER_INVALID_SIGNER);
        };

        let nft: NFTData = NFTData {
            id: object::new(ctx),
            name: string::utf8(nftName),
            description: string::utf8(nftDescription),
            url: url::new_unsafe_from_bytes(nftUrl),
            attributes: attributes::from_vec(attribute_keys, attribute_values)
        };

        mint_event::emit_mint(
            witness::from_witness(Witness {}),
            mint_cap::collection_id(mint_cap),
            &nft,
        );

        transfer::public_transfer(nft, nftReceiverAddress);
    }

    public entry fun deactive_collection(collectionCofing: &mut CollectionConfig, ctx: &mut TxContext) {
        assert!(collectionCofing.updateAuthority == tx_context::sender(ctx), ER_INVALID_UPDATE_AUTHORITY);

        collectionCofing.status = CS_DEACTIVE;
    }

    public entry fun active_collection(collectionCofing: &mut CollectionConfig, ctx: &mut TxContext) {
        assert!(collectionCofing.updateAuthority == tx_context::sender(ctx), ER_INVALID_UPDATE_AUTHORITY);

        collectionCofing.status = CS_ACTIVE;
    }

    public entry fun update_collection_signing_required(
        collectionCofing: &mut CollectionConfig,
        isSigningAuthorityRequired: bool,
        ctx: &mut TxContext
    ) {
        assert!(collectionCofing.updateAuthority == tx_context::sender(ctx), ER_INVALID_UPDATE_AUTHORITY);

        collectionCofing.signingAuthorityRequired = isSigningAuthorityRequired;
    }
}