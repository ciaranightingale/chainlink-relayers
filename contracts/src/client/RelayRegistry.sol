// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol';
import './RelayBase.sol';
import './ConfirmedOwner.sol';
import './interfaces/TypeAndVersionInterface.sol';
import './interfaces/AggregatorV3Interface.sol';
import './interfaces/LinkTokenInterface.sol';
import './interfaces/RelayCompatibleInterface.sol';
import './interfaces/RelayRegistryInterface.sol';
import './interfaces/ERC677ReceiverInterface.sol';
import '../utils/RelayTypes.sol';

/**
 * @notice Registry for adding work for Chainlink Relayers to perform on client
 * contracts. Clients must support the Relay interface.
 */
contract RelayRegistry is
    TypeAndVersionInterface,
    ConfirmedOwner,
    RelayBase,
    ReentrancyGuard,
    Pausable,
    RelayRegistryExecutableInterface,
    ERC677ReceiverInterface,
    EIP712
{
    using ECDSA for bytes32;
    using Address for address;
    using EnumerableSet for EnumerableSet.UintSet;

    address private constant ZERO_ADDRESS = address(0);
    address private constant IGNORE_ADDRESS = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    bytes4 private constant CHECK_SELECTOR = RelayCompatibleInterface.checkRelay.selector;
    bytes4 private constant PERFORM_SELECTOR = RelayCompatibleInterface.performRelay.selector;
    uint256 private constant PERFORM_GAS_MIN = 2_300;
    uint256 private constant CANCELATION_DELAY = 50;
    uint256 private constant PERFORM_GAS_CUSHION = 5_000;
    uint256 private constant REGISTRY_GAS_OVERHEAD = 80_000;
    uint256 private constant PPB_BASE = 1_000_000_000;
    uint64 private constant UINT64_MAX = 2**64 - 1;
    uint96 private constant LINK_TOTAL_SUPPLY = 1e27;
    bytes32 private constant _TYPEHASH =
        keccak256(
            'RelayRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce, bytes data)'
        );

    address[] private s_relayerList;
    EnumerableSet.UintSet private s_relayIDs;
    mapping(uint256 => Relay) private s_relay;
    mapping(address => RelayerInfo) private s_relayerInfo;
    mapping(address => address) private s_proposedPayee;
    mapping(uint256 => bytes) private s_checkData;
    mapping(address => uint256) private _nonces;
    Storage private s_storage;
    uint256 private s_fallbackGasPrice;
    uint256 private s_fallbackLinkPrice;
    uint96 private s_ownerLinkBalance;
    uint256 private s_expectedLinkBalance;
    address private s_registrar;

    LinkTokenInterface public immutable LINK;
    AggregatorV3Interface public immutable LINK_ETH_FEED;
    AggregatorV3Interface public immutable FAST_GAS_FEED;

    /**
     * @notice versions:
     * - RelayRegistry 1.0.0: initial release
     */
    string public constant override typeAndVersion = 'RelayRegistry 1.0.0';

    error CannotCancel();
    error RelayNotActive();
    error RelayNotCanceled();
    error RelayNotNeeded();
    error NotAContract();
    error PaymentGreaterThanAllLINK();
    error OnlyActiveRelayers();
    error InsufficientFunds();
    error RelayersMustTakeTurns();
    error ParameterLengthError();
    error OnlyCallableByOwnerOrAdmin();
    error OnlyCallableByLINKToken();
    error InvalidPayee();
    error DuplicateEntry();
    error ValueNotChanged();
    error IndexOutOfRange();
    error ArrayHasNoEntries();
    error GasLimitOutsideRange();
    error OnlyCallableByPayee();
    error OnlyCallableByProposedPayee();
    error GasLimitCanOnlyIncrease();
    error OnlyCallableByAdmin();
    error OnlyCallableByOwnerOrRegistrar();
    error InvalidRecipient();
    error InvalidDataLength();
    error TargetCheckReverted(bytes reason);

    /**
     * @notice storage of the registry, contains a mix of config and state data
     */
    struct Storage {
        uint32 paymentPremiumPPB;
        uint32 flatFeeMicroLink;
        uint24 blockCountPerTurn;
        uint32 checkGasLimit;
        uint24 stalenessSeconds;
        uint16 gasCeilingMultiplier;
        uint96 minRelaySpend; // 1 evm word
        uint32 maxPerformGas;
        uint32 nonce; // 2 evm words
    }

    struct Relay {
        uint96 balance;
        address lastRelayer; // 1 storage slot full
        uint32 executeGas;
        uint64 maxValidBlocknumber;
        address target; // 2 storage slots full
        uint96 amountSpent;
        address client; // 3 storage slots full
    }

    struct RelayerInfo {
        address payee;
        uint96 balance;
        bool active;
    }

    struct PerformParams {
        address from;
        uint256 id;
        RelayTypes.RelayRequest relayRequest;
        bytes performData;
        uint256 maxLinkPayment;
        uint256 gasLimit;
        uint256 adjustedGasWei;
        uint256 linkEth;
    }

    event RelayRegistered(uint256 indexed id, uint32 executeGas, address admin);
    event RelayPerformed(
        uint256 indexed id,
        bool indexed success,
        address indexed from,
        uint96 payment,
        RelayTypes.RelayRequest relayRequest,
        bytes performData
    );
    event RelayCanceled(uint256 indexed id, uint64 indexed atBlockHeight);
    event FundsAdded(uint256 indexed id, address indexed from, uint96 amount);
    event FundsWithdrawn(uint256 indexed id, uint256 amount, address to);
    event OwnerFundsWithdrawn(uint96 amount);
    event RelayReceived(uint256 indexed id, uint256 startingBalance, address importedFrom);
    event ConfigSet(Config config);
    event RelayersUpdated(address[] relayers, address[] payees);
    event PaymentWithdrawn(
        address indexed relayer,
        uint256 indexed amount,
        address indexed to,
        address payee
    );
    event PayeeshipTransferRequested(
        address indexed relayer,
        address indexed from,
        address indexed to
    );
    event PayeeshipTransferred(address indexed relayer, address indexed from, address indexed to);
    event RelayGasLimitSet(uint256 indexed id, uint96 gasLimit);

    /**
     * @param link address of the LINK Token
     * @param linkEthFeed address of the LINK/ETH price feed
     * @param fastGasFeed address of the Fast Gas price feed
     * @param config registry config settings
     */
    constructor(
        address link,
        address linkEthFeed,
        address fastGasFeed,
        Config memory config
    ) ConfirmedOwner(msg.sender) EIP712('RelayRegistry', '1.0.0') {
        LINK = LinkTokenInterface(link);
        LINK_ETH_FEED = AggregatorV3Interface(linkEthFeed);
        FAST_GAS_FEED = AggregatorV3Interface(fastGasFeed);
        setConfig(config);
    }

    // ACTIONS

    /**
     * @notice adds a new relay
     * @param target address to be submitted for relay
     * @param gasLimit amount of gas to provide the target contract when
     * performing relay
     * @param admin client address to cancel relay and withdraw remaining funds
     * @param checkData data passed to the contract when checking if relay
     * is required for a user
     * @return id the ID associated with the new relay
     */
    function registerRelay(
        address target,
        uint32 gasLimit,
        address admin,
        bytes calldata checkData
    ) external override onlyOwnerOrRegistrar returns (uint256 id) {
        id = uint256(
            keccak256(abi.encodePacked(blockhash(block.number - 1), address(this), s_storage.nonce))
        );
        _createRelay(id, target, gasLimit, admin, 0, checkData);
        s_storage.nonce++;
        emit RelayRegistered(id, gasLimit, admin);
        return id;
    }

    /**
     * @notice simulated by relayers via eth_call to see if the relay needs to be
     * performed and passes checks. If relay is needed, the call then simulates performRelay
     * to make sure it succeeds. Finally, it returns the success status along with
     * payment information and the perform data payload.
     * @param id identifier of the relay to check
     * @param from the address to simulate performing the relay from
     * @param relayRequest the information of the user relay request
     * @param signature the users message signature
     */
    function checkRelay(
        uint256 id,
        address from,
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata signature
    )
        external
        override
        cannotExecute
        returns (
            bytes memory performData,
            uint256 maxLinkPayment,
            uint256 gasLimit,
            uint256 adjustedGasWei,
            uint256 linkEth
        )
    {
        Relay memory relay = s_relay[id];

        require(verify(relayRequest, signature), 'INVALID SIGNER');

        bytes memory callData = abi.encodeWithSelector(
            CHECK_SELECTOR,
            relayRequest,
            s_checkData[id]
        );
        (bool success, bytes memory result) = relay.target.call{gas: s_storage.checkGasLimit}(
            callData
        );

        if (!success) revert TargetCheckReverted(result);

        (success, performData) = abi.decode(result, (bool, bytes));
        if (!success) revert RelayNotNeeded();

        PerformParams memory params = _generatePerformParams(
            from,
            id,
            relayRequest,
            performData,
            false
        );
        _prePerformRelay(relay, params.from, params.maxLinkPayment);

        return (
            performData,
            params.maxLinkPayment,
            params.gasLimit,
            params.adjustedGasWei,
            params.linkEth
        );
    }

    /**
     * @notice executes the relay with the perform data returned from
     * checkRelay, validates the relayer's permissions, and pays the relayer.
     * @param id identifier of the relay to execute the data with.
     * @param performData calldata parameter to be passed to the target relay.
     */
    function performRelay(
        uint256 id,
        RelayTypes.RelayRequest calldata relayRequest,
        bytes calldata performData
    ) external override whenNotPaused returns (bool success) {
        _nonces[relayRequest.from]++;
        return
            _performRelayWithParams(
                _generatePerformParams(msg.sender, id, relayRequest, performData, true)
            );
    }

    /**
     * @notice prevent a relay from being performed in the future
     * @param id relay to be cancelled
     */
    function cancelRelay(uint256 id) external override {
        uint64 maxValid = s_relay[id].maxValidBlocknumber;
        bool canceled = maxValid != UINT64_MAX;
        bool isOwner = msg.sender == owner();

        if (canceled && !(isOwner && maxValid > block.number)) revert CannotCancel();
        if (!isOwner && msg.sender != s_relay[id].client) revert OnlyCallableByOwnerOrAdmin();

        uint256 height = block.number;
        if (!isOwner) {
            height = height + CANCELATION_DELAY;
        }
        s_relay[id].maxValidBlocknumber = uint64(height);
        s_relayIDs.remove(id);

        emit RelayCanceled(id, uint64(height));
    }

    /**
     * @notice adds LINK funding for a relay by transferring from the sender's
     * LINK balance
     * @param id relay to fund
     * @param amount number of LINK to transfer
     */
    function addFunds(uint256 id, uint96 amount) external override onlyActiveRelay(id) {
        s_relay[id].balance = s_relay[id].balance + amount;
        s_expectedLinkBalance = s_expectedLinkBalance + amount;
        LINK.transferFrom(msg.sender, address(this), amount);
        emit FundsAdded(id, msg.sender, amount);
    }

    /**
     * @notice uses LINK's transferAndCall to LINK and add funding to a relay
     * @dev safe to cast uint256 to uint96 as total LINK supply is under UINT96MAX
     * @param sender the account which transferred the funds
     * @param amount number of LINK transfer
     */
    function onTokenTransfer(
        address sender,
        uint256 amount,
        bytes calldata data
    ) external {
        if (msg.sender != address(LINK)) revert OnlyCallableByLINKToken();
        if (data.length != 32) revert InvalidDataLength();
        uint256 id = abi.decode(data, (uint256));
        if (s_relay[id].maxValidBlocknumber != UINT64_MAX) revert RelayNotActive();

        s_relay[id].balance = s_relay[id].balance + uint96(amount);
        s_expectedLinkBalance = s_expectedLinkBalance + amount;

        emit FundsAdded(id, sender, uint96(amount));
    }

    /**
     * @notice removes funding from a canceled relay
     * @param id relay to withdraw funds from
     * @param to destination address for sending remaining funds
     */
    function withdrawFunds(uint256 id, address to) external validRecipient(to) onlyRelayAdmin(id) {
        if (s_relay[id].maxValidBlocknumber > block.number) revert RelayNotCanceled();

        uint96 minRelaySpend = s_storage.minRelaySpend;
        uint96 amountLeft = s_relay[id].balance;
        uint96 amountSpent = s_relay[id].amountSpent;

        uint96 cancellationFee = 0;
        // cancellationFee is supposed to be min(max(minRelaySpend - amountSpent,0), amountLeft)
        if (amountSpent < minRelaySpend) {
            cancellationFee = minRelaySpend - amountSpent;
            if (cancellationFee > amountLeft) {
                cancellationFee = amountLeft;
            }
        }
        uint96 amountToWithdraw = amountLeft - cancellationFee;

        s_relay[id].balance = 0;
        s_ownerLinkBalance = s_ownerLinkBalance + cancellationFee;

        s_expectedLinkBalance = s_expectedLinkBalance - amountToWithdraw;
        emit FundsWithdrawn(id, amountToWithdraw, to);

        LINK.transfer(to, amountToWithdraw);
    }

    /**
     * @notice withdraws LINK funds collected through cancellation fees
     */
    function withdrawOwnerFunds() external onlyOwner {
        uint96 amount = s_ownerLinkBalance;

        s_expectedLinkBalance = s_expectedLinkBalance - amount;
        s_ownerLinkBalance = 0;

        emit OwnerFundsWithdrawn(amount);
        LINK.transfer(msg.sender, amount);
    }

    /**
     * @notice allows clients to modify gas limit of a relay
     * @param id relay to be change the gas limit for
     * @param gasLimit new gas limit for the relay
     */
    function setRelayGasLimit(uint256 id, uint32 gasLimit)
        external
        override
        onlyActiveRelay(id)
        onlyRelayAdmin(id)
    {
        if (gasLimit < PERFORM_GAS_MIN || gasLimit > s_storage.maxPerformGas)
            revert GasLimitOutsideRange();

        s_relay[id].executeGas = gasLimit;

        emit RelayGasLimitSet(id, gasLimit);
    }

    /**
     * @notice recovers LINK funds improperly transferred to the registry
     * @dev In principle this function’s execution cost could exceed block
     * gas limit. However, in our anticipated deployment, the number of relays and
     * relayers will be low enough to avoid this problem.
     */
    function recoverFunds() external onlyOwner {
        uint256 total = LINK.balanceOf(address(this));
        LINK.transfer(msg.sender, total - s_expectedLinkBalance);
    }

    /**
     * @notice withdraws a relayer's payment, callable only by the relayer's payee
     * @param from relayer address
     * @param to address to send the payment to
     */
    function withdrawPayment(address from, address to) external validRecipient(to) {
        RelayerInfo memory relayer = s_relayerInfo[from];
        if (relayer.payee != msg.sender) revert OnlyCallableByPayee();

        s_relayerInfo[from].balance = 0;
        s_expectedLinkBalance = s_expectedLinkBalance - relayer.balance;
        emit PaymentWithdrawn(from, relayer.balance, to, msg.sender);

        LINK.transfer(to, relayer.balance);
    }

    /**
     * @notice proposes the safe transfer of a relayer's payee to another address
     * @param relayer address of the relayer to transfer payee role
     * @param proposed address to nominate for next payeeship
     */
    function transferPayeeship(address relayer, address proposed) external {
        if (s_relayerInfo[relayer].payee != msg.sender) revert OnlyCallableByPayee();
        if (proposed == msg.sender) revert ValueNotChanged();

        if (s_proposedPayee[relayer] != proposed) {
            s_proposedPayee[relayer] = proposed;
            emit PayeeshipTransferRequested(relayer, msg.sender, proposed);
        }
    }

    /**
     * @notice accepts the safe transfer of payee role for a relayer
     * @param relayer address to accept the payee role for
     */
    function acceptPayeeship(address relayer) external {
        if (s_proposedPayee[relayer] != msg.sender) revert OnlyCallableByProposedPayee();
        address past = s_relayerInfo[relayer].payee;
        s_relayerInfo[relayer].payee = msg.sender;
        s_proposedPayee[relayer] = ZERO_ADDRESS;

        emit PayeeshipTransferred(relayer, past, msg.sender);
    }

    /**
     * @notice signals to relayers that they should not perform relays until the
     * contract has been unpaused
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice signals to relayers that they can perform relays once again after
     * having been paused
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // SETTERS

    /**
     * @notice updates the configuration of the registry
     * @param config registry config fields
     */
    function setConfig(Config memory config) public onlyOwner {
        if (config.maxPerformGas < s_storage.maxPerformGas) revert GasLimitCanOnlyIncrease();
        s_storage = Storage({
            paymentPremiumPPB: config.paymentPremiumPPB,
            flatFeeMicroLink: config.flatFeeMicroLink,
            blockCountPerTurn: config.blockCountPerTurn,
            checkGasLimit: config.checkGasLimit,
            stalenessSeconds: config.stalenessSeconds,
            gasCeilingMultiplier: config.gasCeilingMultiplier,
            minRelaySpend: config.minRelaySpend,
            maxPerformGas: config.maxPerformGas,
            nonce: s_storage.nonce
        });
        s_fallbackGasPrice = config.fallbackGasPrice;
        s_fallbackLinkPrice = config.fallbackLinkPrice;
        s_registrar = config.registrar;
        emit ConfigSet(config);
    }

    /**
     * @notice update the list of relayers allowed to perform relay
     * @param relayers list of addresses allowed to perform relay
     * @param payees addresses corresponding to relayers who are allowed to
     * move payments which have been accrued
     */
    function setRelayers(address[] calldata relayers, address[] calldata payees)
        external
        onlyOwner
    {
        if (relayers.length != payees.length || relayers.length < 2) revert ParameterLengthError();
        for (uint256 i = 0; i < s_relayerList.length; i++) {
            address relayer = s_relayerList[i];
            s_relayerInfo[relayer].active = false;
        }
        for (uint256 i = 0; i < relayers.length; i++) {
            address relayer = relayers[i];
            RelayerInfo storage s_relayer = s_relayerInfo[relayer];
            address oldPayee = s_relayer.payee;
            address newPayee = payees[i];
            if (
                (newPayee == ZERO_ADDRESS) ||
                (oldPayee != ZERO_ADDRESS && oldPayee != newPayee && newPayee != IGNORE_ADDRESS)
            ) revert InvalidPayee();
            if (s_relayer.active) revert DuplicateEntry();
            s_relayer.active = true;
            if (newPayee != IGNORE_ADDRESS) {
                s_relayer.payee = newPayee;
            }
        }
        s_relayerList = relayers;
        emit RelayersUpdated(relayers, payees);
    }

    // GETTERS

    /**
     * @notice read all of the details about a relay
     */
    function getRelay(uint256 id)
        external
        view
        override
        returns (
            address target,
            uint32 executeGas,
            bytes memory checkData,
            uint96 balance,
            address lastRelayer,
            address admin,
            uint64 maxValidBlocknumber,
            uint96 amountSpent
        )
    {
        Relay memory reg = s_relay[id];
        return (
            reg.target,
            reg.executeGas,
            s_checkData[id],
            reg.balance,
            reg.lastRelayer,
            reg.client,
            reg.maxValidBlocknumber,
            reg.amountSpent
        );
    }

    /**
     * @notice retrieve active relay IDs
     * @param startIndex starting index in list
     * @param maxCount max count to retrieve (0 = unlimited)
     * @dev the order of IDs in the list is **not guaranteed**, therefore, if making successive calls, one
     * should consider keeping the blockheight constant to ensure a wholistic picture of the contract state
     */
    function getActiveRelayIDs(uint256 startIndex, uint256 maxCount)
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256 maxIdx = s_relayIDs.length();
        if (startIndex >= maxIdx) revert IndexOutOfRange();
        if (maxCount == 0) {
            maxCount = maxIdx - startIndex;
        }
        uint256[] memory ids = new uint256[](maxCount);
        for (uint256 idx = 0; idx < maxCount; idx++) {
            ids[idx] = s_relayIDs.at(startIndex + idx);
        }
        return ids;
    }

    /**
     * @notice read the current info about any relayer address
     */
    function getRelayerInfo(address query)
        external
        view
        override
        returns (
            address payee,
            bool active,
            uint96 balance
        )
    {
        RelayerInfo memory relayer = s_relayerInfo[query];
        return (relayer.payee, relayer.active, relayer.balance);
    }

    /**
     * @notice read the current state of the registry
     */
    function getState()
        external
        view
        override
        returns (
            State memory state,
            Config memory config,
            address[] memory relayers
        )
    {
        Storage memory store = s_storage;
        state.nonce = store.nonce;
        state.ownerLinkBalance = s_ownerLinkBalance;
        state.expectedLinkBalance = s_expectedLinkBalance;
        state.numRelays = s_relayIDs.length();
        config.paymentPremiumPPB = store.paymentPremiumPPB;
        config.flatFeeMicroLink = store.flatFeeMicroLink;
        config.blockCountPerTurn = store.blockCountPerTurn;
        config.checkGasLimit = store.checkGasLimit;
        config.stalenessSeconds = store.stalenessSeconds;
        config.gasCeilingMultiplier = store.gasCeilingMultiplier;
        config.minRelaySpend = store.minRelaySpend;
        config.maxPerformGas = store.maxPerformGas;
        config.fallbackGasPrice = s_fallbackGasPrice;
        config.fallbackLinkPrice = s_fallbackLinkPrice;
        config.registrar = s_registrar;
        return (state, config, s_relayerList);
    }

    /**
     * @notice calculates the minimum balance required for a relay to remain eligible
     * @param id the relay id to calculate minimum balance for
     */
    function getMinBalanceForRelay(uint256 id) external view returns (uint96 minBalance) {
        return getMaxPaymentForGas(s_relay[id].executeGas);
    }

    /**
     * @notice calculates the maximum payment for a given gas limit
     * @param gasLimit the gas to calculate payment for
     */
    function getMaxPaymentForGas(uint256 gasLimit) public view returns (uint96 maxPayment) {
        (uint256 gasWei, uint256 linkEth) = _getFeedData();
        uint256 adjustedGasWei = _adjustGasPrice(gasWei, false);
        return _calculatePaymentAmount(gasLimit, adjustedGasWei, linkEth);
    }

    function verify(RelayTypes.RelayRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        address signer = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _TYPEHASH,
                    req.from,
                    req.to,
                    req.value,
                    req.gas,
                    req.nonce,
                    keccak256(req.data)
                )
            )
        ).recover(signature);
        return _nonces[req.from] == req.nonce && signer == req.from;
    }

    /**
     * @notice creates a new relay with the given fields
     * @param target address to be submitted for relay
     * @param gasLimit amount of gas to provide the target contract when
     * performing relay
     * @param client client address to cancel relay and withdraw remaining funds
     * @param checkData data passed to the contract when checking for relay
     */
    function _createRelay(
        uint256 id,
        address target,
        uint32 gasLimit,
        address client,
        uint96 balance,
        bytes memory checkData
    ) internal whenNotPaused {
        if (!target.isContract()) revert NotAContract();
        if (gasLimit < PERFORM_GAS_MIN || gasLimit > s_storage.maxPerformGas)
            revert GasLimitOutsideRange();
        s_relay[id] = Relay({
            target: target,
            executeGas: gasLimit,
            balance: balance,
            client: client,
            maxValidBlocknumber: UINT64_MAX,
            lastRelayer: ZERO_ADDRESS,
            amountSpent: 0
        });
        s_expectedLinkBalance = s_expectedLinkBalance + balance;
        s_checkData[id] = checkData;
        s_relayIDs.add(id);
    }

    /**
     * @dev retrieves feed data for fast gas/eth and link/eth prices. if the feed
     * data is stale it uses the configured fallback price. Once a price is picked
     * for gas it takes the min of gas price in the transaction or the fast gas
     * price in order to reduce costs for the relay clients.
     */
    function _getFeedData() private view returns (uint256 gasWei, uint256 linkEth) {
        uint32 stalenessSeconds = s_storage.stalenessSeconds;
        bool staleFallback = stalenessSeconds > 0;
        uint256 timestamp;
        int256 feedValue;
        (, feedValue, , timestamp, ) = FAST_GAS_FEED.latestRoundData();
        if ((staleFallback && stalenessSeconds < block.timestamp - timestamp) || feedValue <= 0) {
            gasWei = s_fallbackGasPrice;
        } else {
            gasWei = uint256(feedValue);
        }
        (, feedValue, , timestamp, ) = LINK_ETH_FEED.latestRoundData();
        if ((staleFallback && stalenessSeconds < block.timestamp - timestamp) || feedValue <= 0) {
            linkEth = s_fallbackLinkPrice;
        } else {
            linkEth = uint256(feedValue);
        }
        return (gasWei, linkEth);
    }

    /**
     * @dev calculates LINK paid for gas spent plus a configure premium percentage
     */
    function _calculatePaymentAmount(
        uint256 gasLimit,
        uint256 gasWei,
        uint256 linkEth
    ) private view returns (uint96 payment) {
        uint256 weiForGas = gasWei * (gasLimit + REGISTRY_GAS_OVERHEAD);
        uint256 premium = PPB_BASE + s_storage.paymentPremiumPPB;
        uint256 total = ((weiForGas * (1e9) * (premium)) / (linkEth)) +
            (uint256(s_storage.flatFeeMicroLink) * (1e12));
        if (total > LINK_TOTAL_SUPPLY) revert PaymentGreaterThanAllLINK();
        return uint96(total); // LINK_TOTAL_SUPPLY < UINT96_MAX
    }

    /**
     * @dev calls target address with exactly gasAmount gas and data as calldata
     * or reverts if at least gasAmount gas is not available
     */
    function _callWithExactGas(
        uint256 gasAmount,
        address target,
        bytes memory data
    ) private returns (bool success) {
        assembly {
            let g := gas()
            // Compute g -= PERFORM_GAS_CUSHION and check for underflow
            if lt(g, PERFORM_GAS_CUSHION) {
                revert(0, 0)
            }
            g := sub(g, PERFORM_GAS_CUSHION)
            // if g - g//64 <= gasAmount, revert
            // (we subtract g//64 because of EIP-150)
            if iszero(gt(sub(g, div(g, 64)), gasAmount)) {
                revert(0, 0)
            }
            // solidity calls check that a contract actually exists at the destination, so we do the same
            if iszero(extcodesize(target)) {
                revert(0, 0)
            }
            // call and return whether we succeeded. ignore return data
            success := call(gasAmount, target, 0, add(data, 0x20), mload(data), 0, 0)
        }
        return success;
    }

    /**
     * @dev calls the Relay target with the performData param passed in by the
     * relayer and the exact gas required by the relay
     */
    function _performRelayWithParams(PerformParams memory params)
        private
        nonReentrant
        validRelay(params.id)
        returns (bool success)
    {
        Relay memory relay = s_relay[params.id];
        _prePerformRelay(relay, params.from, params.maxLinkPayment);

        uint256 gasUsed = gasleft();
        bytes memory callData = abi.encodeWithSelector(
            PERFORM_SELECTOR,
            params.relayRequest,
            params.performData
        );
        success = _callWithExactGas(params.gasLimit, relay.target, callData);
        gasUsed = gasUsed - gasleft();

        uint96 payment = _calculatePaymentAmount(gasUsed, params.adjustedGasWei, params.linkEth);

        s_relay[params.id].balance = s_relay[params.id].balance - payment;
        s_relay[params.id].amountSpent = s_relay[params.id].amountSpent + payment;
        s_relay[params.id].lastRelayer = params.from;
        s_relayerInfo[params.from].balance = s_relayerInfo[params.from].balance + payment;

        emit RelayPerformed(
            params.id,
            success,
            params.from,
            payment,
            params.relayRequest,
            params.performData
        );
        return success;
    }

    /**
     * @dev ensures all required checks are passed before a relay is performed
     */
    function _prePerformRelay(
        Relay memory relay,
        address from,
        uint256 maxLinkPayment
    ) private view {
        if (!s_relayerInfo[from].active) revert OnlyActiveRelayers();
        if (relay.balance < maxLinkPayment) revert InsufficientFunds();
        if (relay.lastRelayer == from) revert RelayersMustTakeTurns();
    }

    /**
     * @dev adjusts the gas price to min(ceiling, tx.gasprice) or just uses the ceiling if tx.gasprice is disabled
     */
    function _adjustGasPrice(uint256 gasWei, bool useTxGasPrice)
        private
        view
        returns (uint256 adjustedPrice)
    {
        adjustedPrice = gasWei * s_storage.gasCeilingMultiplier;
        if (useTxGasPrice && tx.gasprice < adjustedPrice) {
            adjustedPrice = tx.gasprice;
        }
    }

    /**
     * @dev generates a PerformParams struct for use in _performRelayWithParams()
     */
    function _generatePerformParams(
        address from,
        uint256 id,
        RelayTypes.RelayRequest calldata relayRequest,
        bytes memory performData,
        bool useTxGasPrice
    ) private view returns (PerformParams memory) {
        uint256 gasLimit = s_relay[id].executeGas;
        (uint256 gasWei, uint256 linkEth) = _getFeedData();
        uint256 adjustedGasWei = _adjustGasPrice(gasWei, useTxGasPrice);
        uint96 maxLinkPayment = _calculatePaymentAmount(gasLimit, adjustedGasWei, linkEth);

        return
            PerformParams({
                from: from,
                id: id,
                relayRequest: relayRequest,
                performData: performData,
                maxLinkPayment: maxLinkPayment,
                gasLimit: gasLimit,
                adjustedGasWei: adjustedGasWei,
                linkEth: linkEth
            });
    }

    // MODIFIERS

    /**
     * @dev ensures a relay is valid
     */
    modifier validRelay(uint256 id) {
        if (s_relay[id].maxValidBlocknumber <= block.number) revert RelayNotActive();
        _;
    }

    /**
     * @dev Reverts if called by anyone other than the client that owns the relay #id
     */
    modifier onlyRelayAdmin(uint256 id) {
        if (msg.sender != s_relay[id].client) revert OnlyCallableByAdmin();
        _;
    }

    /**
     * @dev Reverts if called on a cancelled relay
     */
    modifier onlyActiveRelay(uint256 id) {
        if (s_relay[id].maxValidBlocknumber != UINT64_MAX) revert RelayNotActive();
        _;
    }

    /**
     * @dev ensures that burns don't accidentally happen by sending to the zero
     * address
     */
    modifier validRecipient(address to) {
        if (to == ZERO_ADDRESS) revert InvalidRecipient();
        _;
    }

    /**
     * @dev Reverts if called by anyone other than the contract owner or registrar.
     */
    modifier onlyOwnerOrRegistrar() {
        if (msg.sender != owner() && msg.sender != s_registrar)
            revert OnlyCallableByOwnerOrRegistrar();
        _;
    }
}
