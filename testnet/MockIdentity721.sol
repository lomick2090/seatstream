// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// TESTNET ONLY. Stands in for the identity collection on Base Sepolia: anyone mints any free id below 2000 to
/// themselves. ownerOf reverts for unminted ids, like the real collection. Refuses to deploy on Base or Ethereum.
contract MockIdentity721 {
    uint256 public constant MAX_ID = 2000;
    mapping(uint256 => address) private _owners;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error BadId();
    error Taken();
    error NotOwner();
    error ZeroAddress();

    constructor() {
        require(block.chainid != 1 && block.chainid != 8453, "testnet only");
    }

    function mint(uint256 tokenId) external {
        if (tokenId >= MAX_ID) revert BadId();
        if (_owners[tokenId] != address(0)) revert Taken();
        _owners[tokenId] = msg.sender;
        emit Transfer(address(0), msg.sender, tokenId);
    }

    function ownerOf(uint256 tokenId) external view returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert BadId();
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        if (from != msg.sender || _owners[tokenId] != msg.sender) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}
