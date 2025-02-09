// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract FLIncentiveMultiCat {
    // Publisher (owner) of the contract
    address public publisher;

    // Deadline timestamp (UNIX time)
    uint256 public deadline;

    // Reward pool in Wei
    uint256 public rewardPool;

    // Participant structure
    struct Participant {
        bool joined;
        uint8 dataCat;        // 0 = Low, 1 = Medium, 2 = High
        uint8 resourceCat;    // 0 = Low, 1 = Medium, 2 = High
        uint256 stakePaid;    // Amount of Wei staked
        bool isRewarded;
    }

    // Mapping from participant address to Participant data
    mapping(address => Participant) public participants;

    // Array to keep track of participant addresses
    address[] public participantList;

    // Event declarations
    event ParticipantJoined(address indexed participant, uint8 dataCat, uint8 resourceCat, uint256 stakePaid);
    event ContractFinalized(uint256 rewardPool, uint256 timestamp);

    // Modifier to restrict functions to the publisher
    modifier onlyPublisher() {
        require(msg.sender == publisher, "Only publisher can perform this action.");
        _;
    }

    // Constructor to initialize the contract with a deadline
    constructor(uint256 _deadline) payable {
        require(_deadline > block.timestamp, "Deadline must be in the future.");
        publisher = msg.sender;
        deadline = _deadline;
        rewardPool = msg.value; // Initialize reward pool with the sent ETH
    }

    /**
     * @dev Returns the stake required and reward multiplier based on dataCat and resourceCat.
     * @param dcat Data category (0=Low, 1=Medium, 2=High)
     * @param rcat Resource category (0=Low, 1=Medium, 2=High)
     * @return stakeRequired The amount of Wei required to stake
     * @return rewardMultiplier The multiplier for rewards
     */
    function getComboParams(uint8 dcat, uint8 rcat) public pure returns (uint256 stakeRequired, uint256 rewardMultiplier) {
        require(dcat <= 2, "Invalid data category.");
        require(rcat <= 2, "Invalid resource category.");

        // Define stake and multiplier based on category combinations
        if (dcat == 0 && rcat == 0) {
            stakeRequired = 1 ether;
            rewardMultiplier = 1;
        } else if (dcat == 0 && rcat == 1) {
            stakeRequired = 2 ether;
            rewardMultiplier = 15; // Represents a 1.5x multiplier
        } else if (dcat == 0 && rcat == 2) {
            stakeRequired = 3 ether;
            rewardMultiplier = 2;
        } else if (dcat == 1 && rcat == 0) {
            stakeRequired = 1.5 ether;
            rewardMultiplier = 12; // Represents a 1.2x multiplier
        } else if (dcat == 1 && rcat == 1) {
            stakeRequired = 2.5 ether;
            rewardMultiplier = 18; // Represents a 1.8x multiplier
        } else if (dcat == 1 && rcat == 2) {
            stakeRequired = 3.5 ether;
            rewardMultiplier = 25; // Represents a 2.5x multiplier
        } else if (dcat == 2 && rcat == 0) {
            stakeRequired = 2 ether;
            rewardMultiplier = 15; // Represents a 1.5x multiplier
        } else if (dcat == 2 && rcat == 1) {
            stakeRequired = 3 ether;
            rewardMultiplier = 20; // Represents a 2.0x multiplier
        } else if (dcat == 2 && rcat == 2) {
            stakeRequired = 4 ether;
            rewardMultiplier = 30; // Represents a 3.0x multiplier
        }
    }

    /**
     * @dev Allows a user to join by staking the required amount based on their data and resource categories.
     * @param dcat Data category (0=Low, 1=Medium, 2=High)
     * @param rcat Resource category (0=Low, 1=Medium, 2=High)
     */
    function join(uint8 dcat, uint8 rcat) external payable {
        require(block.timestamp <= deadline, "Deadline has passed.");
        require(!participants[msg.sender].joined, "Already joined.");

        // Fetch required stake and multiplier
        (uint256 stakeRequired, ) = getComboParams(dcat, rcat);

        require(msg.value == stakeRequired, "Incorrect stake payment.");

        // Register the participant
        participants[msg.sender] = Participant({
            joined: true,
            dataCat: dcat,
            resourceCat: rcat,
            stakePaid: msg.value,
            isRewarded: false
        });

        participantList.push(msg.sender);

        emit ParticipantJoined(msg.sender, dcat, rcat, msg.value);
    }

    /**
     * @dev Finalizes the contract by distributing rewards based on multipliers.
     * Can only be called by the publisher after the deadline.
     */
    function finalize() external onlyPublisher {
        require(block.timestamp > deadline, "Cannot finalize before deadline.");

        // Iterate through all participants and distribute rewards
        for (uint256 i = 0; i < participantList.length; i++) {
            address participantAddr = participantList[i];
            Participant storage p = participants[participantAddr];

            if (!p.isRewarded && p.joined) {
                // Fetch reward multiplier
                (, uint256 rewardMultiplier) = getComboParams(p.dataCat, p.resourceCat);

                // Calculate reward (stake * multiplier / 10)
                // Multiplier is represented as an integer (e.g., 15 = 1.5x)
                uint256 reward = (p.stakePaid * rewardMultiplier) / 10;

                // Ensure the contract has enough balance
                require(rewardPool >= reward, "Insufficient reward pool.");

                // Transfer reward to the participant
                payable(participantAddr).transfer(reward);

                // Update reward pool and participant status
                rewardPool -= reward;
                p.isRewarded = true;
            }
        }

        emit ContractFinalized(rewardPool, block.timestamp);
    }

    /**
     * @dev Retrieves the total number of participants.
     * @return count The number of participants.
     */
    function getParticipantCount() external view returns (uint256 count) {
        return participantList.length;
    }

    /**
     * @dev Fallback function to accept ETH directly.
     */
    receive() external payable {
        rewardPool += msg.value;
    }

    fallback() external payable {
        rewardPool += msg.value;
    }
}
