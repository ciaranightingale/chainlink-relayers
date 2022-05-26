// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import '../client/RelayCompatible.sol'; //Imports both ./RelayBase.sol and ./RelayCompatibleInterface.sol
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/** @notice This is an example implementation using Chainlink Relayers. The premis of the example is that if a user is
 * part of the 'club', the client/admin will pay for the user's first transaction.
 */

contract Counter is RelayCompatible {
    error TransferFailed();

    mapping(address => bool) public s_club;
    mapping(address => uint256) public s_counter;
    mapping(address => bool) public s_relayed;

    // keccak256 hash of empty checkData
    bytes32 public constant emptyCheckDataHash =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    address public RELAY_REGISTRY_ADDRESS = 0x6C63d07091f7659fB36ced4D0fdaCa9Bb5e2f782;
    address public deployer;

    event relayCompleted(address user);
    event clubMemberAdded(address user);

    constructor(address[] memory users) {
        for (uint256 user = 0; user < users.length; user++) {
            s_club[users[user]] = true;
        }
        deployer = msg.sender;
    }

    function setRegistry(address registry) external {
        require(msg.sender == deployer);
        RELAY_REGISTRY_ADDRESS = registry;
    }

    function addUserToClub(address user) public {
        // In this example, anyone can call this function, do not use in production
        s_club[user] = true;
        emit clubMemberAdded(user);
    }

    function checkClubMember(address user)
        public
        view
        returns (bool relayNeeded, bytes memory performData)
    {
        relayNeeded = s_club[user];
        performData = abi.encodeWithSelector(this.addToRelayedGroup.selector, user);
    }

    function incrementUserCounter() external {
        s_counter[_msgSenderBase()] += 1;
    }

    function addToRelayedGroup(address user) external {
        // if accepting > 1 per user then use a nonce to prevent replaying transactions
        require(_msgSenderBase() == user, 'Only user');
        s_relayed[user] = true;
    }

    function checkRelay(
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata checkData,
        bytes calldata signature
    ) external view override cannotExecute returns (bool relayNeeded, bytes memory performData) {
        require(!s_relayed[relayRequest.from], 'One relay per user');
        if (keccak256(checkData) == emptyCheckDataHash) {
            performData = checkData;
            relayNeeded = true;
        } else {
            (bool success, bytes memory returnedData) = address(this).staticcall(
                abi.encode(checkData, relayRequest.from)
            );
            require(success);
            (relayNeeded, performData) = abi.decode(returnedData, (bool, bytes));
        }
    }

    function performRelay(RelayTypes.RelayRequest calldata relayRequest, bytes calldata performData)
        external
        override
        onlyRegistry(RELAY_REGISTRY_ADDRESS)
    {
        (bool success, ) = address(this).staticcall(performData);
        require(success, 'RELAY_NOT_VALID');
        bytes memory data = abi.encode(relayRequest.data, relayRequest.from);
        (bool relayed, ) = relayRequest.to.call{gas: relayRequest.gas}(data);
        require(relayed, 'RELAY_FAILED');
        emit relayCompleted(relayRequest.from);
    }
}
