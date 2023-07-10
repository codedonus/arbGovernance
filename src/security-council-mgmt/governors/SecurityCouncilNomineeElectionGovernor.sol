// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "lib/solady/src/utils/DateTimeLib.sol";

import "./SecurityCouncilMemberElectionGovernor.sol";

import "../interfaces/ISecurityCouncilManager.sol";
import "./modules/SecurityCouncilNomineeElectionGovernorCountingUpgradeable.sol";
import "./modules/ArbitrumGovernorVotesQuorumFractionUpgradeable.sol";

import "../SecurityCouncilMgmtUtils.sol";

// note: this contract assumes that there can only be one proposalId with state Active or Succeeded at a time
// (easy to override state() to return `Expired` if a proposal succeeded but hasn't executed after some time)

/// @title SecurityCouncilNomineeElectionGovernor
/// @notice Governor contract for selecting Security Council Nominees (phase 1 of the Security Council election process).
contract SecurityCouncilNomineeElectionGovernor is
    Initializable,
    GovernorUpgradeable,
    GovernorVotesUpgradeable,
    SecurityCouncilNomineeElectionGovernorCountingUpgradeable,
    ArbitrumGovernorVotesQuorumFractionUpgradeable,
    GovernorSettingsUpgradeable,
    OwnableUpgradeable
{
    // todo: these parameters could be reordered to make more sense
    /// @notice parameters for `initialize`
    /// @param targetNomineeCount The target number of nominees to elect (6)
    /// @param firstNominationStartDate First election start date
    /// @param nomineeVettingDuration Duration of the nominee vetting period (expressed in blocks)
    /// @param nomineeVetter Address of the nominee vetter
    /// @param securityCouncilManager Security council manager contract
    /// @param token Token used for voting
    /// @param owner Owner of the governor
    /// @param quorumNumeratorValue Numerator of the quorum fraction (0.2% = 20)
    /// @param votingPeriod Duration of the voting period (expressed in blocks)
    struct InitParams {
        uint256 targetNomineeCount;
        Date firstNominationStartDate;
        uint256 nomineeVettingDuration;
        address nomineeVetter;
        ISecurityCouncilManager securityCouncilManager;
        SecurityCouncilMemberElectionGovernor securityCouncilMemberElectionGovernor;
        IVotesUpgradeable token;
        address owner;
        uint256 quorumNumeratorValue;
        uint256 votingPeriod;
    }

    /// @notice Date struct for convenience
    struct Date {
        uint256 year;
        uint256 month;
        uint256 day;
        uint256 hour;
    }

    /// @notice Information about a nominee election
    /// @param isContender Whether the account is a contender
    /// @param isExcluded Whether the account has been excluded by the nomineeVetter
    /// @param excludedNomineeCount The number of nominees that have been excluded by the nomineeVetter
    struct ElectionInfo {
        mapping(address => bool) isContender;
        mapping(address => bool) isExcluded;
        uint256 excludedNomineeCount;
    }

    event NomineeVetterChanged(address indexed oldNomineeVetter, address indexed newNomineeVetter);
    event ContenderAdded(uint256 indexed proposalId, address indexed contender);
    event NomineeExcluded(uint256 indexed proposalId, address indexed nominee);

    /// @notice The target number of nominees to elect (6)
    uint256 public targetNomineeCount;

    /// @notice First election start date
    Date public firstNominationStartDate;

    /// @notice Duration of the nominee vetting period (expressed in blocks)
    /// @dev    This is the amount of time after voting ends that the nomineeVetter can exclude noncompliant nominees
    uint256 public nomineeVettingDuration;

    /// @notice Address responsible for blocking non compliant nominees
    address public nomineeVetter;

    /// @notice Security council manager contract
    /// @dev    Used to execute the election result immediately if <= 6 compliant nominees are chosen
    ISecurityCouncilManager public securityCouncilManager;

    /// @notice Security council member election governor contract
    SecurityCouncilMemberElectionGovernor public securityCouncilMemberElectionGovernor;

    /// @notice Number of elections created
    uint256 public electionCount;

    /// @notice Maps proposalId to ElectionInfo
    mapping(uint256 => ElectionInfo) internal _elections;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the governor
    function initialize(InitParams memory params) public initializer {
        require(
            DateTimeLib.isSupportedDateTime({
                year: params.firstNominationStartDate.year,
                month: params.firstNominationStartDate.month,
                day: params.firstNominationStartDate.day,
                hour: params.firstNominationStartDate.hour,
                minute: 0,
                second: 0
            }),
            "SecurityCouncilNomineeElectionGovernor: Invalid first nomination start date"
        );

        // make sure the start date is in the future
        uint256 startTimestamp = DateTimeLib.dateTimeToTimestamp({
            year: params.firstNominationStartDate.year,
            month: params.firstNominationStartDate.month,
            day: params.firstNominationStartDate.day,
            hour: params.firstNominationStartDate.hour,
            minute: 0,
            second: 0
        });

        require(
            startTimestamp > block.timestamp,
            "SecurityCouncilNomineeElectionGovernor: First nomination start date must be in the future"
        );

        __Governor_init("Security Council Nominee Election Governor");
        __GovernorVotes_init(params.token);
        __SecurityCouncilNomineeElectionGovernorCounting_init();
        __ArbitrumGovernorVotesQuorumFraction_init(params.quorumNumeratorValue);
        __GovernorSettings_init(0, params.votingPeriod, 0); // votingDelay and proposalThreshold are set to 0
        _transferOwnership(params.owner);

        targetNomineeCount = params.targetNomineeCount;
        firstNominationStartDate = params.firstNominationStartDate;
        nomineeVettingDuration = params.nomineeVettingDuration;
        nomineeVetter = params.nomineeVetter;
        securityCouncilManager = params.securityCouncilManager;
        securityCouncilMemberElectionGovernor = params.securityCouncilMemberElectionGovernor;
    }

    /// @notice Allows the nominee vetter to call certain functions
    modifier onlyNomineeVetter() {
        require(
            msg.sender == nomineeVetter,
            "SecurityCouncilNomineeElectionGovernor: Only the nomineeVetter can call this function"
        );
        _;
    }

    /**
     * permissionless state mutating functions *************
     */

    /// @notice Creates a new nominee election proposal.
    ///         Can be called by anyone every `nominationFrequency` seconds.
    /// @return proposalId The id of the proposal
    function createElection() external returns (uint256 proposalId) {
        // CHRIS: TODO: we need to check elections cannot have a time less than all the stages put together when initialising
        uint256 thisElectionStartTs = electionToTimestamp(firstNominationStartDate, electionCount);

        require(
            block.timestamp >= thisElectionStartTs,
            "SecurityCouncilNomineeElectionGovernor: Not enough time has passed since the last election"
        );

        proposalId = GovernorUpgradeable.propose(
            new address[](1),
            new uint256[](1),
            new bytes[](1),
            electionIndexToDescription(electionCount)
        );

        electionCount++;
    }

    /// @notice Put `msg.sender` up for nomination. Must be called before a contender can receive votes.
    /// @dev    Can be called only while a proposal is active (in voting phase)
    ///         A contender cannot be a member of the opposite cohort.
    function addContender(uint256 proposalId) external {
        ElectionInfo storage election = _elections[proposalId];
        require(
            !election.isContender[msg.sender],
            "SecurityCouncilNomineeElectionGovernor: Account is already a contender"
        );

        ProposalState state = state(proposalId);
        require(
            state == ProposalState.Active,
            "SecurityCouncilNomineeElectionGovernor: Proposal is not active"
        );

        // check to make sure the contender is not part of the other cohort
        Cohort cohort = electionIndexToCohort(electionCount - 1);

        address[] memory oppositeCohortCurrentMembers = cohort == Cohort.SECOND
            ? securityCouncilManager.getFirstCohort()
            : securityCouncilManager.getSecondCohort();

        require(
            !SecurityCouncilMgmtUtils.isInArray(msg.sender, oppositeCohortCurrentMembers),
            "SecurityCouncilNomineeElectionGovernor: Account is a member of the opposite cohort"
        );

        election.isContender[msg.sender] = true;

        emit ContenderAdded(proposalId, msg.sender);
    }
    
    /// @notice Allows the owner to change the nomineeVetter
    function setNomineeVetter(address _nomineeVetter) external onlyOwner {
        address oldNomineeVetter = nomineeVetter;
        nomineeVetter = _nomineeVetter;
        emit NomineeVetterChanged(oldNomineeVetter, _nomineeVetter);
    }

    /// @notice Allows the owner to make calls from the governor
    /// @dev    See {L2ArbitrumGovernor-relay}
    function relay(address target, uint256 value, bytes calldata data)
        external
        virtual
        override
        onlyOwner
    {
        AddressUpgradeable.functionCallWithValue(target, data, value);
    }

    /// @notice Allows the nomineeVetter to exclude a noncompliant nominee.
    /// @dev    Can be called only after a proposal has succeeded (voting has ended) and before the nominee vetting period has ended.
    ///         Will revert if the provided account is not a nominee (had less than the required votes).
    function excludeNominee(uint256 proposalId, address account) external onlyNomineeVetter {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "SecurityCouncilNomineeElectionGovernor: Proposal has not succeeded"
        );
        require(
            block.number <= proposalVettingDeadline(proposalId),
            "SecurityCouncilNomineeElectionGovernor: Proposal is no longer in the nominee vetting period"
        );

        ElectionInfo storage election = _elections[proposalId];
        require(!election.isExcluded[account], "Nominee already excluded");

        election.isExcluded[account] = true;
        election.excludedNomineeCount++;

        emit NomineeExcluded(proposalId, account);
    }

    /// @notice Allows the nomineeVetter to explicitly include a nominee
    /// @dev    Can be called only after a proposal has succeeded (voting has ended) and before the nominee vetting period has ended.
    ///         Will revert if the provided account is already a nominee
    function includeNominee(uint256 proposalId, address account) external onlyNomineeVetter {
        require(
            state(proposalId) == ProposalState.Succeeded,
            "SecurityCouncilNomineeElectionGovernor: Proposal has not succeeded"
        );
        require(
            block.number <= proposalVettingDeadline(proposalId),
            "SecurityCouncilNomineeElectionGovernor: Proposal is no longer in the nominee vetting period"
        );
        require(
            !isNominee(proposalId, account),
            "SecurityCouncilNomineeElectionGovernor: Nominee already added"
        );

        Cohort cohort = electionIndexToCohort(electionCount - 1);
        if (cohort == Cohort.FIRST) {
            require(
                !securityCouncilManager.secondCohortIncludes(account),
                "SecurityCouncilNomineeElectionGovernor: Cannot add member of other second cohort"
            );
        } else {
            require(
                !securityCouncilManager.firstCohortIncludes(account),
                "SecurityCouncilNomineeElectionGovernor: Cannot add member of other first cohort"
            );
        }

        addNominee(proposalId, account);

        emit NewNominee(proposalId, account);
    }

    /**
     * internal/private state mutating functions
     */

    /// @dev    `GovernorUpgradeable` function to execute a proposal overridden to handle nominee elections.
    ///         Can be called by anyone via `execute` after voting and nominee vetting periods have ended.
    ///         If the number of compliant nominees is > the target number of nominees,
    ///         we move on to the next phase by calling the SecurityCouncilMemberElectionGovernor.
    ///         If the number of compliant nominees is == the target number of nominees,
    ///         we execute the election result immediately by calling the SecurityCouncilManager.
    ///         If the number of compliant nominees is < the target number of nominees,
    ///         we randomly add some members from the current cohort to the list of nominees and then call the SecurityCouncilManager.
    /// @param  proposalId The id of the proposal
    function _execute(
        uint256 proposalId,
        address[] memory, /* targets */
        uint256[] memory, /* values */
        bytes[] memory, /* calldatas */
        bytes32 /*descriptionHash*/
    ) internal virtual override {
        require(
            block.number > proposalVettingDeadline(proposalId),
            "SecurityCouncilNomineeElectionGovernor: Proposal is still in the nominee vetting period"
        );

        ElectionInfo storage election = _elections[proposalId];

        uint256 compliantNomineeCount = nomineeCount(proposalId) - election.excludedNomineeCount;

        if (compliantNomineeCount == targetNomineeCount) {
            address[] memory maybeCompliantNominees =
                SecurityCouncilNomineeElectionGovernorCountingUpgradeable.nominees(proposalId);
            address[] memory compliantNominees = SecurityCouncilMgmtUtils
                .filterAddressesWithExcludeList(maybeCompliantNominees, election.isExcluded);
            Cohort cohort = electionIndexToCohort(electionCount - 1);
            securityCouncilMemberElectionGovernor.executeElectionResult(compliantNominees, cohort);
        } else if (compliantNomineeCount > targetNomineeCount) {
            // call the SecurityCouncilMemberElectionGovernor to start the next phase of the election
            securityCouncilMemberElectionGovernor.proposeFromNomineeElectionGovernor();
            return;
        } else {
            revert(
                "SecurityCouncilNomineeElectionGovernor: Insufficient number of compliant nominees"
            );
        }
    }

    /**
     * view/pure functions *************
     */

    /// @notice returns true if the account is a nominee for the most recent election and has not been excluded
    /// @param  account The account to check
    function isCompliantNomineeForMostRecentElection(address account)
        external
        view
        returns (bool)
    {
        return isCompliantNominee(electionIndexToProposalId(electionCount - 1), account);
    }

    /// @notice Normally "the number of votes required in order for a voter to become a proposer." But in our case it is 0.
    /// @dev    Since we only want proposals to be created via `createElection`, we set the proposal threshold to 0.
    ///         `createElection` determines the rules for creating a proposal.
    function proposalThreshold()
        public
        view
        virtual
        override(GovernorSettingsUpgradeable, GovernorUpgradeable)
        returns (uint256)
    {
        return 0;
    }

    /// @notice returns true if the account is a nominee for the given proposal and has not been excluded
    /// @param  proposalId The id of the proposal
    /// @param  account The account to check
    function isCompliantNominee(uint256 proposalId, address account) public view returns (bool) {
        return isNominee(proposalId, account) && !_elections[proposalId].isExcluded[account];
    }

    /// @notice Returns the deadline for the nominee vetting period for a given `proposalId`
    function proposalVettingDeadline(uint256 proposalId) public view returns (uint256) {
        return proposalDeadline(proposalId) + nomineeVettingDuration;
    }

    /// @notice Returns the start timestamp of an election
    /// @param firstElection The start date of the first election
    /// @param electionIndex The index of the election
    function electionToTimestamp(Date memory firstElection, uint256 electionIndex)
        public
        pure
        returns (uint256)
    {
        // subtract one to make month 0 indexed
        uint256 month = firstElection.month - 1;

        month += 6 * electionIndex;
        uint256 year = firstElection.year + month / 12;
        month = month % 12;

        // add one to make month 1 indexed
        month += 1;

        return DateTimeLib.dateTimeToTimestamp({
            year: year,
            month: month,
            day: firstElection.day,
            hour: firstElection.hour,
            minute: 0,
            second: 0
        });
    }

    /// @notice Returns the cohort for a given `electionIndex`
    function electionIndexToCohort(uint256 electionIndex) public pure returns (Cohort) {
        return Cohort(electionIndex % 2);
    }

    function cohortOfMostRecentElection() external view returns (Cohort) {
        return electionIndexToCohort(electionCount - 1);
    }

    /// @notice Returns the description for a given `electionIndex`
    function electionIndexToDescription(uint256 electionIndex)
        public
        pure
        returns (string memory)
    {
        return string.concat("Nominee Election #", StringsUpgradeable.toString(electionIndex));
    }

    /// @notice Returns the proposalId for a given `electionIndex`
    function electionIndexToProposalId(uint256 electionIndex) public pure returns (uint256) {
        return hashProposal(
            new address[](1),
            new uint256[](1),
            new bytes[](1),
            keccak256(bytes(electionIndexToDescription(electionIndex)))
        );
    }

    /**
     * internal view/pure functions *************
     */

    /// @inheritdoc SecurityCouncilNomineeElectionGovernorCountingUpgradeable
    function _isContender(uint256 proposalId, address possibleContender)
        internal
        view
        virtual
        override
        returns (bool)
    {
        return _elections[proposalId].isContender[possibleContender];
    }

    /**
     * disabled functions *************
     */

    /// @notice Always reverts.
    /// @dev    `GovernorUpgradeable` function to create a proposal overridden to just revert.
    ///         We only want proposals to be created via `createElection`.
    function propose(address[] memory, uint256[] memory, bytes[] memory, string memory)
        public
        virtual
        override
        returns (uint256)
    {
        revert(
            "SecurityCouncilNomineeElectionGovernor: Proposing is not allowed, call createElection instead"
        );
    }
}
