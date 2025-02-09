// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IFLIncentive {
    function participantList() external view returns (address[] memory);
    function participants(address) external view returns (
        uint8 dataCat,
        uint8 resourceCat,
        uint96 stakePaid,
        uint40 joinTime,
        bool isRewarded,
        bool joined
    );
    function currentPhase() external view returns (uint8);
}

contract FLConsensus {
    // 核心状态变量
    address public immutable incentiveContract;
    uint256 public flRound;
    bool public isFLActive;
    
    // FL运行参数
    uint256 public minParticipants;
    uint256 public modelUpdateTimeout;
    uint256 public currentRoundDeadline;
    
    // 参与者状态跟踪
    struct FLParticipant {
        bool submittedUpdate;
        uint256 submissionTime;
        bytes32 modelHash;
    }
    mapping(uint256 => mapping(address => FLParticipant)) public flParticipants;

    // 事件系统
    event FLStarted(uint256 indexed round, address[] participants);
    event ModelSubmitted(address indexed participant, uint256 round, bytes32 modelHash);
    event FLCompleted(uint256 indexed round, bytes32 aggregatedModel);

    constructor(
        address _incentiveContract,
        uint256 _minParticipants,
        uint256 _modelTimeout
    ) {
        incentiveContract = _incentiveContract;
        minParticipants = _minParticipants;
        modelUpdateTimeout = _modelTimeout;
    }

    // 核心功能函数
    modifier onlyValidParticipants() {
        require(
            IFLIncentive(incentiveContract).currentPhase() == 2, // CLOSED phase
            "Incentive phase not closed"
        );
        _;
    }

    function startFLRound() external onlyValidParticipants {
        address[] memory eligible = getEligibleParticipants();
        require(eligible.length >= minParticipants, "Insufficient participants");
        
        flRound++;
        isFLActive = true;
        currentRoundDeadline = block.timestamp + modelUpdateTimeout;
        
        _initializeParticipants(eligible);
        emit FLStarted(flRound, eligible);
    }

    function getEligibleParticipants() public view returns (address[] memory) {
        address[] memory all = IFLIncentive(incentiveContract).participantList();
        address[] memory eligible = new address[](all.length);
        uint256 count;
        
        for (uint256 i = 0; i < all.length; i++) {
            (, , , , bool isRewarded, ) = IFLIncentive(incentiveContract).participants(all[i]);
            if (isRewarded) {
                eligible[count++] = all[i];
            }
        }
        
        // 裁剪数组
        assembly { mstore(eligible, count) }
        return eligible;
    }

    function submitModelUpdate(bytes32 _modelHash) external {
        require(isFLActive, "FL not active");
        require(block.timestamp < currentRoundDeadline, "Round expired");
        require(_isEligible(msg.sender), "Not eligible participant");
        
        flParticipants[flRound][msg.sender] = FLParticipant({
            submittedUpdate: true,
            submissionTime: block.timestamp,
            modelHash: _modelHash
        });
        
        emit ModelSubmitted(msg.sender, flRound, _modelHash);
    }

    function _isEligible(address _user) internal view returns (bool) {
        (, , , , bool isRewarded, ) = IFLIncentive(incentiveContract).participants(_user);
        return isRewarded && !flParticipants[flRound][_user].submittedUpdate;
    }

    function completeFLRound(bytes32 _aggregatedHash) external {
        require(isFLActive, "FL ongoing");
        require(block.timestamp > currentRoundDeadline, "Round ongoing");
        
        _validateAggregation(_aggregatedHash);
        
        isFLActive = false;
        emit FLCompleted(flRound, _aggregatedHash);
    }

    // 预留聚合验证接口
    function _validateAggregation(bytes32) internal virtual {
        // 实际聚合验证逻辑
    }

    // 资金管理函数
    function withdrawRemaining() external {
        require(!isFLActive, "FL ongoing");
        // 资金管理逻辑
    }

    // 内部初始化函数
    function _initializeParticipants(address[] memory participants) internal {
        // 初始化参与者状态
    }
}