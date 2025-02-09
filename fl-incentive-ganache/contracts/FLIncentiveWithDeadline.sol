// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title FLIncentiveWithDeadline
 * @notice Demonstrates an incentive contract with a maximum tolerance time
 *         (deadline) for participants to join.
 */
contract FLIncentiveWithDeadline {
    // -----------------------
    // DATA STRUCTURES
    // -----------------------

    /// @dev Represents an item in the "menu of contracts" (stake tiers).
    struct ContractItem {
        uint256 stakeAmount;      // required stake in wei
        uint256 minDataRequired;  // minimal data threshold (for demonstration)
        uint256 rewardMultiplier; // factor to scale final reward
    }

    /// @dev Holds participant info.
    struct Participant {
        bool joined;
        uint256 chosenItem;  // index in the items array
        uint256 stakePaid;
        bool isRewarded;
    }

    // -----------------------
    // STATE VARIABLES
    // -----------------------
    
    ContractItem[] public items;                // The menu of contract items
    mapping(address => Participant) public participants;  
    address[] public participantList;           

    uint256 public totalRewardPool;  // Ether allocated by the publisher
    bool public isClosed;            // Whether the contract has been finalized

    // -----------------------
    // NEW: Deadline
    // -----------------------
    uint256 public deadline; // The absolute timestamp after which no new joins are allowed

    // -----------------------
    // EVENTS
    // -----------------------
    event ItemAdded(uint256 itemId, uint256 stake, uint256 dataReq, uint256 multiplier);
    event ParticipantJoined(address indexed participant, uint256 itemId, uint256 stake);
    event Finalized(address indexed caller);

    // -----------------------
    // CONSTRUCTOR
    // -----------------------
    /**
     * @dev The publisher deploys this contract with an initial reward pool (in msg.value) 
     *      and sets a maximum tolerance time (deadline) for participants to join.
     * @param _deadlineTimestamp The unix timestamp by which all participants must have joined.
     */
    constructor(uint256 _deadlineTimestamp) payable {
        require(msg.value > 0, "Need an initial reward pool");
        require(_deadlineTimestamp > block.timestamp, "Deadline must be in the future");

        totalRewardPool = msg.value;
        isClosed = false;
        deadline = _deadlineTimestamp;

        // Sample: add 3 contract items
        items.push(ContractItem({
            stakeAmount: 5 ether,
            minDataRequired: 10000,
            rewardMultiplier: 3
        }));
        items.push(ContractItem({
            stakeAmount: 2 ether,
            minDataRequired: 3000,
            rewardMultiplier: 2
        }));
        items.push(ContractItem({
            stakeAmount: 0.5 ether,
            minDataRequired: 500,
            rewardMultiplier: 1
        }));
    }

    // -----------------------
    // CORE FUNCTIONS
    // -----------------------

    /**
     * @dev A participant chooses one of the contract items 
     *      (0, 1, or 2 in this example) and stakes the required amount.
     *      They must do this BEFORE the deadline.
     */
    function join(uint256 _itemId) external payable {
        require(!isClosed, "Contract already finalized");
        require(block.timestamp < deadline, "Deadline passed for joining");
        require(_itemId < items.length, "Invalid itemId");

        ContractItem memory chosen = items[_itemId];
        require(msg.value == chosen.stakeAmount, "Incorrect stake payment");

        Participant storage p = participants[msg.sender];
        require(!p.joined, "Already joined");

        p.joined = true;
        p.chosenItem = _itemId;
        p.stakePaid = msg.value;
        participantList.push(msg.sender);

        emit ParticipantJoined(msg.sender, _itemId, msg.value);
    }

    /**
     * @dev Called after the deadline to distribute rewards.
     *      In a real system, you might do aggregator checks, etc. 
     *      For now, we simply reward proportionally by rewardMultiplier.
     */
    function finalize() external {
        require(!isClosed, "Already finalized");
        require(block.timestamp >= deadline, "Cannot finalize before deadline");

        isClosed = true;

        // Sum total multipliers
        uint256 totalMultiplier = 0;
        for (uint256 i = 0; i < participantList.length; i++) {
            address addr = participantList[i];
            Participant storage p = participants[addr];
            // For demonstration, ignoring actual data checks 
            // (in production you'd verify minDataRequired, etc.)
            uint256 mult = items[p.chosenItem].rewardMultiplier;
            totalMultiplier += mult;
        }

        // Distribute the totalRewardPool in proportion to each participant's multiplier
        if (totalMultiplier > 0) {
            for (uint256 i = 0; i < participantList.length; i++) {
                address addr = participantList[i];
                Participant storage p = participants[addr];
                uint256 mult = items[p.chosenItem].rewardMultiplier;

                uint256 rewardShare = (mult * totalRewardPool) / totalMultiplier;
                (bool success, ) = addr.call{value: rewardShare}("");
                require(success, "Reward transfer failed");
                p.isRewarded = true;
            }
        }

        emit Finalized(msg.sender);
    }

    // -----------------------
    // HELPER VIEWS
    // -----------------------
    function getItemCount() external view returns (uint256) {
        return items.length;
    }

    function getParticipantCount() external view returns (uint256) {
        return participantList.length;
    }
}
