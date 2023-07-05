<h1>Mirror World Sui Asset Minting Contract</h1>

# Asset Minting
The Asset Minting Contract allow user to create Collection with Limited or Unlimited NFT quantity. The Contract is build on top of the Origin Byte ["NFT Protocol"](https://github.com/Origin-Byte/nft-protocol) standard.

# Components
The Main Components of the Asset Minting Contract:

# Collection Config
The Collection Config have the info about the collection that is collection "Active" or "Deactivate", Who can update the collection etc

# NFT Data
The NFT Data is the main Asset in sui which have the nft info name, description, image url and attributes (keys and values)

# Methods

# create_collection_create_authority_cap
This method create authority which can create collections but only admin cap create the collection authority cap

# create_collection
This method create the collection and mint cap with collection authority cap

# mint_nft
This method mint NFT with mint cap and description, image url, attributes (keys and values) and nft receiver address

# deactive_collection
This method deactivate the collection only update authority can deactivate the collection from collection config

# active_collection
This method activate the collection only update authority can activate the collection from collection config