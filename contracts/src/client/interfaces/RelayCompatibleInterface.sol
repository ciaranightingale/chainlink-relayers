// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../../utils/RelayTypes.sol';

/**
 * @title The abstract class used to build relay compatible contracts.
 *
 * @notice A base contract to be inherited by any contract that want to receive relayed transactions.
 *
 * @notice A subclass must use `_msgSender()` instead of `msg.sender`.
 *
 * @dev Note may need to split forwarder specifications from the rest
 */

interface RelayCompatibleInterface {
    /**
     * @notice method that is simulated by the relayers to see if any relays need to
     * be performed. This method does does not actually need to be
     * executable, and since it is only ever simulated it can consume lots of gas.
     * @dev To ensure that it is never called, you may want to add the
     * cannotExecute modifier from RelayBase to your implementation of this
     * method.
     * @param relayRequest data describing the specific transaction submitted for relay
     * @param checkData specified in the relay registration so it is always the
     * same for a registered relay. This can easily be broken down into specific
     * arguments using `abi.decode`, so multiple relays can be registered on the
     * same contract and easily differentiated by the contract.
     * @param signature the message signature from the user of a specific transaction.
     * @return relayNeeded boolean to indicate whether the Relayer should perform the relay
     * for the transaction
     * @return performData bytes that the Relayer should call performRelay with, if
     * relay is needed. If you would like to encode data to decode later, try
     * `abi.encode`.
     */
    function checkRelay(
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata checkData,
        bytes calldata signature
    ) external returns (bool relayNeeded, bytes memory performData);

    /**
     * @notice method that is actually executed by the relayers, via the registry.
     * The data returned by the checkRelay simulation will be passed into
     * this method to actually be executed.
     * @dev The input to this method should not be trusted, and the caller of the
     * method should not even be restricted to any single registry. Anyone should
     * be able call it, and the input should be validated, there is no guarantee
     * that the data passed in is the performData returned from checkRelay. This
     * could happen due to malicious relayers, racing relayers, or simply a state
     * change while the performRelay transaction is waiting for confirmation.
     * Always validate the data passed in.
     * @param performData is the data which was passed back from the checkData
     * simulation. If it is encoded, it can easily be decoded into other types by
     * calling `abi.decode`. This data should not be trusted, and should be
     * validated against the contract's current state.
     */
    function performRelay(RelayTypes.RelayRequest calldata relayRequest, bytes calldata performData)
        external;
}
