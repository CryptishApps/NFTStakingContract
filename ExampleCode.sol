// SPDX-License-Identifier: MIT

/* 

An in-progress code sample

*/ 

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";


interface IERC721 {
    function batchTransferFrom(address _from, address _to, uint256[] memory _tokenIDs) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function balanceOf(address _owner) external returns (uint);
}

interface IUSDC {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ExampleCode is ERC721, Ownable {

    event LockedNFTMinted(address _mintedAddress, uint256 _mintedId);
    event LockedNFTTraded(address _ownerAddress, uint256 _nftid);
    event RewardsClaimed(address _ownerAddress, uint256 _amount);

    IERC721 public NFTContract;
    IERC721 public GenesisNFT;
    IUSDC public USDCContract;

    address public councilAddress;
    bool public stakingActive = false;
    uint256 public rebasePercentage;
    uint256 public softResetFrequency;
    uint256 public softResetPercentage;
    uint256 public holderStakedCount;
    uint256 public startTimestamp;
    uint256 public rewardBalance;
    uint256 public rewardThreshold;
    uint256 constant v1LastID = 99; // 92 nfts with IDs from 1 - 99
    uint256 constant v2LastID = 5049; // IDs are 0-5049
    uint256 constant maxNFTCount = 5142; 
    uint256 public totalStakedCount;

    struct StakedToken {
        address owner;
        uint256 stakedTimestamp;
        uint256 weight;
        uint256 originalID;
        bool isV1;
    }

    struct SoftReset {
        uint256 timestamp;
        uint256 percentage; /// @dev 1% would = 1 and 49% would = 49
    }

    struct DayWeight {
        uint256 daysSinceStart;
        uint256 weight;
    }

    DayWeight[] dayWeights;
    SoftReset[] softResets;

    mapping(uint256 => StakedToken) public stakedTokens; 
    mapping(address => uint256) public rewardBalances;
    mapping(address => bool) public whitelistedUpdates;
    mapping(uint256 => uint256) public dailyWeights;
    mapping(uint256 => address) public custodialWallets;

    modifier isActive() {
        require(stakingActive == true, "Staking not currently active");
        _;
    }

    constructor(
        address _v1Address, 
        address _v2Address,
        address _usdcAddress,
        uint256 _rebase,
        uint256 _resetPerc
    ) ERC721("Example Contract", "EXAMPLE") {
        GenesisNFT = IERC721(_v1Address);
        NFTContract = IERC721(_v2Address);
        USDCContract = IUSDC(_usdcAddress);
        rebasePercentage = _rebase;
        softResetPercentage = _resetPerc;
        rewardThreshold = 5e9;
    }

    /**
        @dev owner functions
    */
    function setDepositsActive(bool _status) public onlyOwner() {
        stakingActive = _status;
        startTimestamp = block.timestamp;
    }

    function setRebasePercentage(uint256 _newRebase) public onlyOwner() {
        rebasePercentage = _newRebase;
    }

    function setSoftResetPercentage(uint256 _newPerc) public onlyOwner() {
        softResetPercentage = _newPerc;
    }

    function setCouncilAddress (address _councilAddress) public onlyOwner() {
        councilAddress = _councilAddress;
    }

    function setRewardThreshold (uint256 _threshold) public onlyOwner() {
        rewardThreshold = _threshold;
    }

    function setWhitelistedUpdater(address _updater, bool _canUpdate) public onlyOwner() {
        whitelistedUpdates[_updater] = _canUpdate;
    }

    function applySoftReset(uint256 _percentage) public {
        require(
            whitelistedUpdates[_msgSender()] == true 
                || owner() == _msgSender()
                || _msgSender() == councilAddress, 
            "You are not whitelisted for this action"
        );
        softResets.push(SoftReset(block.timestamp, _percentage));
        recalculateWeights();
    }

    /**
        @dev public getter functions
    */
    function totalOriginalsOwned(address _add) public returns(uint) {
        return GenesisNFT.balanceOf(_add) + NFTContract.balanceOf(_add);
    }

    function getTokenInfo(uint256 _tokenID) public view returns (StakedToken memory) {
        return stakedTokens[_tokenID];
    }

    function availableRewards(address _staker) public view returns(uint256) {
        return rewardBalances[_staker];
    }

    function daysSinceDates(uint256 _from, uint256 _to) internal pure returns(uint256) {
        return ((_to - _from) * 1 days)/86400;
    }

    /**
        @dev staking functions
    */

    function recalculateWeights() public {
        for (uint256 i = 0; i <= (v1LastID + v2LastID); i++) {
            if (stakedTokens[i].weight > 0) {
                uint256 collectionWeight = stakedTokens[i].isV1 ? 2 : 1;
                uint256 weight = calculateWeight(stakedTokens[i].stakedTimestamp, collectionWeight);
                stakedTokens[i].weight = weight;
            }
        }
    }

    function calculateWeight(uint256 _from, uint256 _multiplier) internal view returns(uint256) {
        /**
         * TODO: Just need to test
         */
        uint256 daysSince = daysSinceDates(startTimestamp, _from);
        bool hasPriorReset;
        for (uint256 i = softResets.length; i > 0; i--) {
            if (softResets[i-1].timestamp < _from) {
                hasPriorReset = true;
                break;
            }
        }
        if (hasPriorReset == false) {
            return ((1e18 + (rebasePercentage*1e16))**daysSince) * _multiplier;
        } else {
            DayWeight memory lastDailyRecord = dayWeights[dayWeights.length-1];
            uint256 prevWeight = lastDailyRecord.weight;
            uint256 prevDaysSince = lastDailyRecord.daysSinceStart;
            uint256 missingDays = daysSince - prevDaysSince + 1;
            uint256 ydayWeight = prevWeight*(1e18+(rebasePercentage*1e16)) ** missingDays;

            return ((1e18 + (rebasePercentage*1e16)) * (ydayWeight-(ydayWeight-1e18) * softResetPercentage)) * _multiplier;
        }
    }
    
    function mintLockedNFTs(uint256[] memory _tokenIDs, bool isV1) internal {
        /// @dev genesis nfts get double the weight
        uint256 collectionWeight = isV1 ? 2 : 1;
        uint256 weight = calculateWeight(block.timestamp, collectionWeight);
        address sender = _msgSender();

        uint256 daysSince = daysSinceDates(startTimestamp, block.timestamp);
        dayWeights.push(DayWeight(daysSince, weight));

        for (uint256 i = 0; i < _tokenIDs.length; i++) {
            uint256 id = isV1 ? _tokenIDs[i] + v2LastID : _tokenIDs[i];
            address currentLockedOwner = ownerOf(id);
            require(
                currentLockedOwner != address(0) && currentLockedOwner != address(this),
                "Already minted and staked"
            );
            if (!_exists(id)) {
                mintLLZ(id);
                emit LockedNFTMinted(sender, id);
            } else {
                _safeTransfer(address(this), sender, id, "");
                emit LockedNFTTraded(sender, id);
            }
            custodialWallets[id] = _msgSender();
            stakedTokens[id] = StakedToken(sender, block.timestamp, weight, _tokenIDs[i], isV1);
            totalStakedCount++;
        }
    }

    function mintLLZ(uint256 _tokenId) internal {
        _mint(_msgSender(), _tokenId);
    }

    function stakeNft(
        uint256[] memory _v1TokenIDs, 
        uint256[] memory _v2TokenIDs
    ) public isActive() {
        address sender = _msgSender();
        require (
            _v1TokenIDs.length > 0 || _v2TokenIDs.length > 0, 
            "Requires at least NFT"
        );
        require (
           totalOriginalsOwned(sender) > 0,
            "No V1 or V2 nfts owned"
        );

        /** 
            @dev batchTransferFrom checks the owner
        */ 
        if (_v1TokenIDs.length > 0) {
            GenesisNFT.batchTransferFrom(sender, address(this), _v1TokenIDs);
            mintLockedNFTs(_v1TokenIDs, true);
        }
        if (_v2TokenIDs.length > 0) {
            NFTContract.batchTransferFrom(sender, address(this), _v2TokenIDs);
            mintLockedNFTs(_v2TokenIDs, false);
        }
    }
    
    function unstakeNfts(uint256[] memory _tokenIDs) public {
        for (uint256 i = 0; i < _tokenIDs.length; i++) {
            uint256 tokenID = _tokenIDs[i];
            uint256 originalID = stakedTokens[tokenID].originalID;
            transferFrom(msg.sender, address(this), originalID);
            stakedTokens[tokenID].stakedTimestamp = block.timestamp;
            stakedTokens[tokenID].weight = 0;
            if (stakedTokens[tokenID].isV1 == true) {
                GenesisNFT.transferFrom(address(this), msg.sender, originalID);
            } else {
                NFTContract.transferFrom(address(this), msg.sender, originalID);
            }
            custodialWallets[tokenID] = address(this);
            totalStakedCount--;
        }
    }

    /**
     * @dev council functions
    */

    function getStakedNfts() internal view returns(StakedToken[] memory) {
        /**
         * @dev have to account for genesis nfts that skip ID increaments
         * e.g. there is no ID 98 but there is 99
         * TODO: Should check gas costs for 
         */
        StakedToken[] memory stakedNfts;
        uint256 allNfts = v1LastID + v2LastID;
        for (uint256 i = 0; i <= allNfts; i ++) {
            if (stakedTokens[i].weight > 0) {
                stakedNfts[stakedNfts.length-1] = stakedTokens[i];
            }
        }
        return stakedNfts;
    }

    function totalWeights(StakedToken[] memory stakedNfts) internal pure returns(uint256) {
        uint256 weights;
        for (uint256 i = 0; i < stakedNfts.length; i++) {
            weights += stakedNfts[i].weight;
        }
        return weights;
    }

    function makeRewardsClaimable(uint256 totalRewards) public onlyOwner() {
        
        recalculateWeights();

        StakedToken[] memory stakedNfts = getStakedNfts();
        uint256 totalWeight = totalWeights(stakedNfts);

        /**
         * TODO: Check math here doesn't cause any issues
         * with sending rounded numbers or anything as the last
         * to receive revdis may error due to not enough funds
         */
        

        for (uint256 i = 0; i < stakedNfts.length; i++) {
            address owner = stakedNfts[i].owner;
            uint256 poolShare = ((stakedNfts[i].weight / totalWeight) * 1e18);
            uint256 usdcReward = (poolShare/1e18) * totalRewards;
            /// TODO: need to check this...
            /// can't really be sending a % of total USDC like this
            rewardBalances[owner] += usdcReward;
        }
        /// @dev test gas efficiency
        // delete dayWeights;
    }

    function depositRewards (uint256 _depositAmount) public {
        require(msg.sender == councilAddress, "Only the council can deposit rewards");
        uint256 currentBalance = USDCContract.balanceOf(address(this)) + _depositAmount;
        USDCContract.transferFrom(msg.sender, address(this), _depositAmount);
        /**
         * @dev make claimable when USDC >= threshold (default is $50k)
         */
        if (currentBalance >= rewardThreshold) {
            makeRewardsClaimable(currentBalance);
        }
    }

    function claimReward() public {
        uint256 available = rewardBalances[msg.sender];
        require(available > 0, "No rewards to claim");
        rewardBalances[msg.sender] = 0;
        USDCContract.transferFrom(address(this), msg.sender, available);
        emit RewardsClaimed(msg.sender, available);
    }

    function recoverCustody(uint256 _tokenID) public {
        require(custodialWallets[_tokenID] == msg.sender, 
            "This function can only be called by the original owner of the locked nft");
        _safeTransfer(ownerOf(_tokenID), _msgSender(), _tokenID, "");
    }
}