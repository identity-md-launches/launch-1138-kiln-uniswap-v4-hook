// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ERC-721 standing in for Pepeolithic in tests: ownership, approvals and `transferFrom` with the
///         standard authorization rules. No receiver callbacks are ever made, like a plain `transferFrom`.
///         `balanceOf(address(0))` reverts like the OpenZeppelin v5 ERC721 the real Pepeolithic inherits, and
///         `setBalanceOfReverts` makes every `balanceOf` revert so the Kiln's fallback to tier 0 can be exercised.
contract MockPepeo {
    string public constant name = "Mock Pepeolithic";
    string public constant symbol = "PEPEO";

    bool public balanceOfReverts;
    mapping(uint256 => address) internal _owner;
    mapping(address => uint256) internal _balance;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event Approval(address indexed owner, address indexed approved, uint256 indexed id);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error ERC721InvalidOwner(address owner);

    function mint(address to, uint256 id) external {
        require(_owner[id] == address(0), "PEPEO: exists");
        _owner[id] = to;
        _balance[to] += 1;
        emit Transfer(address(0), to, id);
    }

    function setBalanceOfReverts(bool reverts) external {
        balanceOfReverts = reverts;
    }

    function balanceOf(address owner) external view returns (uint256) {
        require(!balanceOfReverts, "PEPEO: balanceOf disabled");
        if (owner == address(0)) revert ERC721InvalidOwner(address(0));
        return _balance[owner];
    }

    function ownerOf(uint256 id) external view returns (address owner) {
        owner = _owner[id];
        require(owner != address(0), "PEPEO: no token");
    }

    function approve(address spender, uint256 id) external {
        address owner = _owner[id];
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "PEPEO: not authorized");
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(from == _owner[id], "PEPEO: wrong from");
        require(to != address(0), "PEPEO: zero to");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender] || msg.sender == getApproved[id],
            "PEPEO: not authorized"
        );
        _balance[from] -= 1;
        _balance[to] += 1;
        _owner[id] = to;
        delete getApproved[id];
        emit Transfer(from, to, id);
    }
}
