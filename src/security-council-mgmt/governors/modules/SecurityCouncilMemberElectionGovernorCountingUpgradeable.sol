// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.16;

import "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";

/// @title  SecurityCouncilMemberElectionGovernorCountingUpgradeable
/// @notice Counting module for the SecurityCouncilMemberElectionGovernor.
///         Voters can spread their votes across multiple nominees.
///         Implements linearly decreasing voting weights over time.
///         Uses AccountRankerUpgradeable to keep track of the top K nominees and their weights (where K is the number of nominees we want to select to become members).
abstract contract SecurityCouncilMemberElectionGovernorCountingUpgradeable is
    Initializable,
    GovernorUpgradeable
{
    struct ElectionInfo {
        mapping(address => uint256) votesUsed;
        mapping(address => uint256) weightReceived;
        mapping(address => bool) nomineeHasVotes;
        address[] nomineesWithVotes;
    }

    uint256 private constant WAD = 1e18;

    /// @notice Duration of full weight voting (expressed in blocks)
    uint256 private _fullWeightDuration;

    /// @notice Target number of members to elect
    uint256 private _targetMemberCount;

    mapping(uint256 => ElectionInfo) private _elections;

    // would this be more useful if reason was included?
    /// @notice Emitted when a vote is cast for a nominee
    /// @param voter The account that is casting the vote
    /// @param proposalId The id of the proposal
    /// @param nominee The nominee that is receiving the vote
    /// @param votes The amount of votes that were just cast for the nominee
    /// @param weight The weight of the vote that was just cast for the nominee
    /// @param totalUsedVotes The total amount of votes the voter has used for this proposal
    /// @param totalUsableVotes The total amount of votes the voter has available for this proposal
    event VoteCastForNominee(
        address indexed voter,
        uint256 indexed proposalId,
        address indexed nominee,
        uint256 votes,
        uint256 weight,
        uint256 totalUsedVotes,
        uint256 totalUsableVotes
    );

    /// @param targetMemberCount The maximum number of nominees to track
    /// @param initialFullWeightDuration Duration of full weight voting (expressed in blocks)
    function __SecurityCouncilMemberElectionGovernorCounting_init(
        uint256 targetMemberCount,
        uint256 initialFullWeightDuration
    ) internal onlyInitializing {
        _targetMemberCount = targetMemberCount;
        _fullWeightDuration = initialFullWeightDuration;
    }

    /// @notice Returns the duration of full weight voting (expressed in blocks)
    function fullWeightDuration() public view returns (uint256) {
        return _fullWeightDuration;
    }

    /// @notice Set the full weight duration numerator and total duration denominator
    function setFullWeightDuration(
        uint256 newFullWeightDuration
    ) public onlyGovernance {
        require(
            newFullWeightDuration <= votingPeriod(),
            "SecurityCouncilMemberElectionGovernorCountingUpgradeable: Full weight duration must be <= votingPeriod"
        );
    }

    /// @notice Returns the number of votes used by an account for a given proposal
    function votesUsed(uint256 proposalId, address account) public view returns (uint256) {
        return _elections[proposalId].votesUsed[account];
    }

    function COUNTING_MODE() public pure virtual override returns (string memory) {
        return "TODO: ???";
    }

    /// @notice Returns true if the account has voted any amount for any nominee in the proposal
    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return votesUsed(proposalId, account) > 0;
    }

    /// @notice Returns true, since there is no minimum quorum
    function _quorumReached(uint256) internal pure override returns (bool) {
        return true;
    }

    /// @notice Returns true if votes have been cast for at least K nominees
    function _voteSucceeded(uint256 proposalId) internal view override returns (bool) {
        return _elections[proposalId].nomineesWithVotes.length >= _targetMemberCount;
    }

    /// @notice Register a vote by some account for a proposal.
    /// @dev    Reverts if the account does not have enough votes.
    ///         Reverts if the possibleNominee is not a compliant nominee of the most recent election.
    ///         Weight of the vote is determined using the votesToWeight function.
    ///         Finally, the weight of the vote is added to the weight of the possibleNominee and the top K nominees are updated if necessary.
    /// @param  proposalId The id of the proposal
    /// @param  account The account that is voting
    /// @param  availableVotes The amount of votes that account had at the time of the proposal snapshot
    /// @param  params Abi encoded (address possibleNominee, uint256 votes)
    function _countVote(
        uint256 proposalId,
        address account,
        uint8,
        uint256 availableVotes,
        bytes memory params
    ) internal virtual override {
        require(params.length > 0, "SecurityCouncilMemberElectionGovernorCountingUpgradeable: Must cast vote with params");

        (address nominee, uint256 votes) = abi.decode(params, (address, uint256));

        require(
            _isCompliantNomineeForMostRecentElection(nominee),
            "SecurityCouncilMemberElectionGovernorCountingUpgradeable: Nominee is not compliant"
        );

        uint256 weight = votesToWeight(proposalId, block.number, votes);

        require(
            weight > 0,
            "SecurityCouncilMemberElectionGovernorCountingUpgradeable: Cannot cast 0 weight vote"
        );

        ElectionInfo storage election = _elections[proposalId];

        uint256 prevVotesUsed = election.votesUsed[account];

        require(
            prevVotesUsed + votes <= availableVotes,
            "SecurityCouncilMemberElectionGovernorCountingUpgradeable: Cannot use more votes than available"
        );

        election.votesUsed[account] = prevVotesUsed + votes;
        election.weightReceived[nominee] += weight;
        
        if (!election.nomineeHasVotes[nominee]) {
            election.nomineeHasVotes[nominee] = true;
            election.nomineesWithVotes.push(nominee);
        }

        emit VoteCastForNominee({
            voter: account,
            proposalId: proposalId,
            nominee: nominee,
            votes: votes,
            weight: weight,
            totalUsedVotes: prevVotesUsed + votes,
            totalUsableVotes: availableVotes
        });
    }

    function fullWeightVotingDeadline(uint256 proposalId) public view returns (uint256) {
        uint256 startBlock = proposalSnapshot(proposalId);

        return startBlock + _fullWeightDuration;
    }

    /// @notice Returns the weight of a vote for a given proposal, block number, and number of votes.
    /// @dev    Uses a piecewise linear function to determine the weight of a vote.
    function votesToWeight(uint256 proposalId, uint256 blockNumber, uint256 votes)
        public
        view
        returns (uint256)
    {
        // Votes cast before T+14 days will have 100% weight.
        // Votes cast between T+14 days and T+28 days will have weight based on the time of casting,
        // decreasing linearly with time, with 100% weight at T+14 days, decreasing linearly to 0% weight at T+28 days.

        // 7 days full weight, 14 days decreasing weight

        // do i have an off-by-one in here?

        uint256 endBlock = proposalDeadline(proposalId);
        uint256 startBlock = proposalSnapshot(proposalId);

        if (blockNumber <= startBlock || blockNumber > endBlock) {
            return 0;
        }

        uint256 fullWeightVotingDeadline_ = fullWeightVotingDeadline(proposalId);

        if (blockNumber <= fullWeightVotingDeadline_) {
            return votes;
        }

        // slope denominator
        uint256 decreasingWeightDuration = endBlock - fullWeightVotingDeadline_;

        // slope numerator is -votes, slope denominator is decreasingWeightDuration, delta x is blockNumber - fullWeightVotingDeadline_
        // y intercept is votes
        uint256 decreaseAmount =
            WAD * votes * (blockNumber - fullWeightVotingDeadline_) / decreasingWeightDuration / WAD;

        return decreaseAmount >= votes ? 0 : votes - decreaseAmount;
    }

    function topNominees(uint256 proposalId) public view returns (address[] memory) {
        address[] memory nominees = _elections[proposalId].nomineesWithVotes;
        uint256[] memory weights = new uint256[](nominees.length);
        ElectionInfo storage election = _elections[proposalId];
        for (uint256 i = 0; i < nominees.length; i++) {
            weights[i] = election.weightReceived[nominees[i]];
        }
        return selectTopNominees(nominees, weights, _targetMemberCount);
    }

    function selectTopNominees(address[] memory nominees, uint256[] memory weights, uint256 k)
        public
        pure
        returns (address[] memory)
    {
        revert("TODO");
    }

    /// @dev Returns true if the possibleNominee is a compliant nominee for the most recent election
    function _isCompliantNomineeForMostRecentElection(address possibleNominee)
        internal
        view
        virtual
        returns (bool);

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[46] private __gap;
}
