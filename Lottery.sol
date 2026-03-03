// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract Lottery is VRFConsumerBaseV2 {
    mapping(address => bool) operators;

    // Chainlink VRF v2 configuration
    VRFCoordinatorV2Interface private COORDINATOR;
    uint64 public s_subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 3;

    // VRF request tracking
    mapping(uint256 => bytes) public requestIdToLotteryId;
    mapping(bytes => bool) public lotteryRandomRequested;

    // lottery info
    struct LotteryCycle {
        bytes previousId;
        bytes id;
        uint8 index;
        bool isActive;
        uint256 totalBalances;
        uint256 remains;
        uint8[] result;
        uint256 expired;
        uint8 types;
    }

    struct LotteryInfo {
        uint256 totalBalances;
        mapping(uint8 => LotteryCycle) cycles;
        mapping(bytes => uint8) ids;
        uint8 totalCylces;
    }

    LotteryInfo public lotteries;

    // ticket info

    struct LotteryTicket {
        uint8[] numbers;
        address buyer;
        bool isClaimed;
    }

    struct LotteryTickets {
        mapping(bytes => LotteryTicket) tickets;
        mapping(bytes32 => uint8) amountPerDraw;
    }

    mapping(bytes => LotteryTickets) lotteryTickets;

    // lottery setting
    struct LotterySetting {
        uint8 numberSetting;
        uint8 maximunSetting;
        uint256 price;
        mapping(uint8 => uint8) rates;
    }
    mapping(bytes => LotterySetting) public lotterySettings;
    mapping(uint8 => LotterySetting) public settingDefault;


    constructor(
        address vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId
    ) VRFConsumerBaseV2(vrfCoordinator) {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        keyHash = _keyHash;
        s_subscriptionId = _subscriptionId;

        settingDefault[uint8(1)].numberSetting = 5;
        settingDefault[uint8(1)].maximunSetting = 50;
        settingDefault[uint8(1)].price = 10000000000;
        settingDefault[uint8(1)].rates[1] = 60;
        settingDefault[uint8(1)].rates[2] = 20;
        settingDefault[uint8(1)].rates[3] = 10;

        settingDefault[uint8(2)].numberSetting = 3;
        settingDefault[uint8(2)].maximunSetting = 6;
        settingDefault[uint8(2)].price = 10000000000;

        operators[msg.sender] = true;
    }

    function getLatestLottery() public view returns (LotteryCycle memory) {
        require(lotteries.totalCylces > 0, "Haven't had any lottery, yet");
        return lotteries.cycles[lotteries.totalCylces - 1];
    }

    function getLotteryResult(bytes memory _id)
        public
        view
        returns (uint8[] memory)
    {
        return lotteries.cycles[lotteries.ids[_id]].result;
    }

    function getLotteryInfo(bytes memory _id)
        public
        view
        returns (LotteryCycle memory)
    {
        return lotteries.cycles[lotteries.ids[_id]];
    }

    function inactiveLottery(bytes memory _id) public {
        require(operators[msg.sender] == true, "Permission required");

        uint8 idx = lotteries.ids[_id];
        if (lotteries.totalCylces == 0 || idx >= lotteries.totalCylces) {
            return;
        }

        LotteryCycle storage cycle = lotteries.cycles[idx];
        if (cycle.isActive == true && !lotteryRandomRequested[_id]) {
            _requestRandomWordsForLottery(_id);
            cycle.isActive = false;
        }
    }

    function activeNewLottery(
        bytes memory _idNew,
        bytes memory _idOld,
        uint256 expired,
        uint8 types
    ) public {
        require(operators[msg.sender] == true, "Permission required");
        inactiveLottery(_idOld);
        uint8[] memory result;
        LotteryCycle memory cycle = LotteryCycle(
            _idOld,
            _idNew,
            lotteries.totalCylces,
            true,
            0,
            0,
            result,
            expired,
            types
        );
        lotteries.cycles[lotteries.totalCylces] = cycle;
        lotteries.ids[_idNew] = lotteries.totalCylces;
        lotterySettings[_idNew].numberSetting = settingDefault[types]
            .numberSetting;
        lotterySettings[_idNew].maximunSetting = settingDefault[types]
            .maximunSetting;
        lotterySettings[_idNew].price = settingDefault[types].price;
        uint8 i = 0;
        while (settingDefault[types].rates[i] != 0) {
            lotterySettings[_idNew].rates[i] = settingDefault[types].rates[i];
            i++;
        }
        lotteries.totalCylces++;
    }

    function claimReward(bytes memory _idLottery, bytes memory _idTicket)
        public
    {
        require(
            lotteryTickets[_idLottery].tickets[_idTicket].buyer == msg.sender,
            "Not buyer"
        );
        require(
            lotteryTickets[_idLottery].tickets[_idTicket].isClaimed == false,
            "Already claimed"
        );
        uint8[] memory numbers = lotteryTickets[_idLottery]
            .tickets[_idTicket]
            .numbers;

        if (lotteries.cycles[lotteries.ids[_idLottery]].types == 1) {
            uint8[] memory result = lotteries
                .cycles[lotteries.ids[_idLottery]]
                .result;
            require(result.length > 0, "Result not ready");
            uint8 numberMatched = compare2Arrays(result, numbers);
            uint8 rate = lotterySettings[_idLottery].rates[
                numberMatched - uint8(result.length) + 1
            ];
            require(rate > 0, "Incapable of claiming reward");
            uint8 amountOfDraw = getQuantityOfDrawPerLottery(
                _idLottery,
                numbers
            );
            uint256 prize = ((uint256(
                lotteries.cycles[lotteries.ids[_idLottery]].totalBalances
            ) * uint256(rate)) / 100) / uint256(amountOfDraw);

            lotteries.cycles[lotteries.ids[_idLottery]].totalBalances -= prize;
            lotteries.totalBalances -= prize;
            lotteryTickets[_idLottery].tickets[_idTicket].isClaimed = true;
            // return prize;
            payable(msg.sender).transfer(prize);
        } else {
            revert("Not support lottery type");
        }
    }

    function buyTicket(
        bytes memory _idLottery,
        bytes memory _idTicket,
        uint8[] memory numbers
    ) public payable {
        LotteryCycle memory currentLottery = getLotteryInfo(_idLottery);
        require(
            msg.value == lotterySettings[_idLottery].price,
            "Price is wrong"
        );
        require(currentLottery.isActive == true, "Must buy in active lottery");
        require(
            numbers.length == lotterySettings[_idLottery].numberSetting,
            "Number in ticket is invalid"
        );
        require(
            checkDuplicate(numbers, uint8(numbers.length)) == false,
            "Number in ticket must not duplicated"
        );
        require(
            block.timestamp <= currentLottery.expired - 60 * 15,
            "Lottery is closed."
        );
        require(currentLottery.types == 1, "Invalid lottery type");

        LotteryTicket memory ticket = LotteryTicket(numbers, msg.sender, false);
        bytes32 numberPerDraw = keccak256(abi.encodePacked(numbers));
        lotteryTickets[_idLottery].amountPerDraw[numberPerDraw]++;
        lotteryTickets[_idLottery].tickets[_idTicket] = ticket;

        lotteries.cycles[lotteries.ids[_idLottery]].totalBalances += msg.value;
        lotteries.totalBalances += msg.value;
    }

    function getQuantityOfDrawPerLottery(
        bytes memory _id,
        uint8[] memory numbers
    ) internal view returns (uint8) {
        require(
            numbers.length == lotterySettings[_id].numberSetting,
            "Number in ticket is invalid"
        );
        bytes32 numberPerDraw = keccak256(abi.encodePacked(numbers));
        return lotteryTickets[_id].amountPerDraw[numberPerDraw];
    }

    function _requestRandomWordsForLottery(bytes memory _id) internal {
        require(!lotteryRandomRequested[_id], "Random already requested");

        uint8 idx = lotteries.ids[_id];
        require(idx < lotteries.totalCylces, "Invalid lottery id");

        uint32 numWords = 1;
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );

        requestIdToLotteryId[requestId] = _id;
        lotteryRandomRequested[_id] = true;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        bytes memory _id = requestIdToLotteryId[requestId];
        require(_id.length != 0, "Unknown requestId");

        uint8 idx = lotteries.ids[_id];
        require(idx < lotteries.totalCylces, "Invalid lottery id");

        LotteryCycle storage cycle = lotteries.cycles[idx];
        require(!cycle.isActive, "Lottery still active");

        uint8 numbersCount = lotterySettings[_id].numberSetting;
        uint8 maxNumber = lotterySettings[_id].maximunSetting;
        require(numbersCount > 0 && maxNumber > 0, "Invalid settings");

        uint8[] memory result = new uint8[](numbersCount);
        uint256 seed = randomWords[0];

        for (uint8 i = 0; i < numbersCount; i++) {
            uint8 candidate;
            do {
                candidate = uint8(
                    (uint256(keccak256(abi.encode(seed, i))) % maxNumber) + 1
                );
            } while (_containsPrefix(result, i, candidate));
            result[i] = candidate;
        }

        quickSort(result, uint8(0), uint8(result.length - 1));
        cycle.result = result;
    }

    function _containsPrefix(
        uint8[] memory arr,
        uint8 length,
        uint8 value
    ) internal pure returns (bool) {
        for (uint8 i = 0; i < length; i++) {
            if (arr[i] == value) {
                return true;
            }
        }
        return false;
    }

    function quickSort(
        uint8[] memory arr,
        uint8 left,
        uint8 right
    ) internal pure {
        uint8 i = left;
        uint8 j = right;
        if (i == j) return;
        uint8 pivot = arr[uint8(left + (right - left) / 2)];
        while (i <= j) {
            while (arr[uint8(i)] < pivot) i++;
            while (pivot < arr[uint8(j)]) j--;
            if (i <= j) {
                (arr[uint8(i)], arr[uint8(j)]) = (arr[uint8(j)], arr[uint8(i)]);
                i++;
                j--;
            }
        }
        if (left < j) quickSort(arr, left, j);
        if (i < right) quickSort(arr, i, right);
    }

    function checkDuplicate(uint8[] memory arr, uint8 length)
        internal
        pure
        returns (bool)
    {
        for (uint8 i = 0; i < length - 1; i++) {
            for (uint8 j = i + 1; j < length; j++) {
                if (arr[i] == arr[j] && arr[j] > 0) return true;
            }
        }
        return false;
    }

    function compare2Arrays(uint8[] memory arr1, uint8[] memory arr2)
        internal
        pure
        returns (uint8)
    {
        uint8 amount;
        for (uint8 i = 0; i < arr1.length; i++) {
            for (uint8 j = 0; j < arr2.length; j++) {
                if (arr1[i] == arr2[j]) {
                    amount++;
                    break;
                }
            }
        }
        return amount;
    }
}
