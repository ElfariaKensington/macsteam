// Reverse-engineered steamclient struct layouts (arm64)
#ifndef MACSTEAM_STEAM_TYPES_H
#define MACSTEAM_STEAM_TYPES_H

#include <stdint.h>
#include <stddef.h>
#include "constants.h"

// CAppOwnershipInfo (out-param of CUser::CheckAppOwnership)
typedef struct __attribute__((packed)) {
    int32_t  subId;             // 0x00
    int32_t  releaseState;      // 0x04
    uint32_t owner;             // 0x08
    int32_t  masterSubApp;      // 0x0C
    uint32_t trialTime;         // 0x10
    uint8_t  _pad14[0x1C - 0x14];
    uint32_t purchaseTime;      // 0x1C
    uint32_t realOwner;         // 0x20
    uint8_t  ownsLicense;       // 0x24
    uint8_t  licenseExpired;    // 0x25
    uint8_t  _pad26;            // 0x26
    uint8_t  lowViolence;       // 0x27
    uint8_t  freeLicense;       // 0x28
    uint8_t  regionRestricted;  // 0x29
    uint8_t  fromFreeWeekend;   // 0x2A
    uint8_t  licenseLocked;     // 0x2B
    uint8_t  _pad2C;            // 0x2C
    uint8_t  retailLicense;     // 0x2D
    uint8_t  autoGrant;         // 0x2E
    uint8_t  licensePermanent;  // 0x2F
    uint8_t  _pad30[0x35 - 0x30];
    uint8_t  familyShared;      // 0x35
    uint8_t  _pad36[0x38 - 0x36];
} AppOwnershipInfo_t;

_Static_assert(sizeof(AppOwnershipInfo_t)                     == 0x38, "size");
_Static_assert(offsetof(AppOwnershipInfo_t, subId)            == 0x00, "subId");
_Static_assert(offsetof(AppOwnershipInfo_t, releaseState)     == 0x04, "releaseState");
_Static_assert(offsetof(AppOwnershipInfo_t, owner)            == 0x08, "owner");
_Static_assert(offsetof(AppOwnershipInfo_t, masterSubApp)     == 0x0C, "masterSubApp");
_Static_assert(offsetof(AppOwnershipInfo_t, trialTime)        == 0x10, "trialTime");
_Static_assert(offsetof(AppOwnershipInfo_t, purchaseTime)     == 0x1C, "purchaseTime");
_Static_assert(offsetof(AppOwnershipInfo_t, realOwner)        == 0x20, "realOwner");
_Static_assert(offsetof(AppOwnershipInfo_t, ownsLicense)      == 0x24, "ownsLicense");
_Static_assert(offsetof(AppOwnershipInfo_t, licenseExpired)   == 0x25, "licenseExpired");
_Static_assert(offsetof(AppOwnershipInfo_t, lowViolence)      == 0x27, "lowViolence");
_Static_assert(offsetof(AppOwnershipInfo_t, freeLicense)      == 0x28, "freeLicense");
_Static_assert(offsetof(AppOwnershipInfo_t, regionRestricted) == 0x29, "regionRestricted");
_Static_assert(offsetof(AppOwnershipInfo_t, fromFreeWeekend)  == 0x2A, "fromFreeWeekend");
_Static_assert(offsetof(AppOwnershipInfo_t, licenseLocked)    == 0x2B, "licenseLocked");
_Static_assert(offsetof(AppOwnershipInfo_t, retailLicense)    == 0x2D, "retailLicense");
_Static_assert(offsetof(AppOwnershipInfo_t, autoGrant)        == 0x2E, "autoGrant");
_Static_assert(offsetof(AppOwnershipInfo_t, licensePermanent) == 0x2F, "licensePermanent");
_Static_assert(offsetof(AppOwnershipInfo_t, familyShared)     == 0x35, "familyShared");

// CLicense
typedef struct __attribute__((packed)) {
    uint8_t  _pad00[0x08];
    void    *arena;             // 0x08
    uint8_t  _pad10[0x18 - 0x10];
    void    *countryStr;        // 0x18
    uint32_t packageId;         // 0x20
    uint32_t timeCreated;       // 0x24
    uint32_t timeNextProcess;   // 0x28
    int32_t  minuteLimit;       // 0x2C
    int32_t  minutesUsed;       // 0x30
    uint32_t paymentMethod;     // 0x34
    uint32_t flags;             // 0x38
    uint8_t  _pad3C[0x58 - 0x3C];
    uint32_t licenseType;       // 0x58
    int32_t  territoryCode;     // 0x5C
    int32_t  changeNumber;      // 0x60
    uint32_t ownerId;           // 0x64
} License_t;

_Static_assert(offsetof(License_t, arena)           == 0x08, "arena");
_Static_assert(offsetof(License_t, countryStr)      == 0x18, "countryStr");
_Static_assert(offsetof(License_t, packageId)       == 0x20, "packageId");
_Static_assert(offsetof(License_t, timeCreated)     == 0x24, "timeCreated");
_Static_assert(offsetof(License_t, timeNextProcess) == 0x28, "timeNextProcess");
_Static_assert(offsetof(License_t, minuteLimit)     == 0x2C, "minuteLimit");
_Static_assert(offsetof(License_t, minutesUsed)     == 0x30, "minutesUsed");
_Static_assert(offsetof(License_t, paymentMethod)   == 0x34, "paymentMethod");
_Static_assert(offsetof(License_t, flags)           == 0x38, "flags");
_Static_assert(offsetof(License_t, licenseType)     == 0x58, "licenseType");
_Static_assert(offsetof(License_t, territoryCode)   == 0x5C, "territoryCode");
_Static_assert(offsetof(License_t, changeNumber)    == 0x60, "changeNumber");
_Static_assert(offsetof(License_t, ownerId)         == 0x64, "ownerId");

// CProtoBufMsg
typedef struct __attribute__((packed)) {
    uint8_t  _pad00[0x20];
    uint32_t eMsg;              // 0x20
    uint8_t  _pad24[0x38 - 0x24];
    void    *body;              // 0x38 (0x30 up to build 1788652215)
} CProtoBufMsg_t;

_Static_assert(offsetof(CProtoBufMsg_t, eMsg) == 0x20, "eMsg");
_Static_assert(offsetof(CProtoBufMsg_t, body) == 0x38, "body");

// CNetPacket
typedef struct __attribute__((packed)) {
    uint8_t  _pad00[0x08];
    uint8_t *pubData;           // 0x08
    uint32_t cubData;           // 0x10
} CNetPacket_t;

_Static_assert(offsetof(CNetPacket_t, pubData) == 0x08, "pubData");
_Static_assert(offsetof(CNetPacket_t, cubData) == 0x10, "cubData");

// CUtlVector<int>
typedef struct __attribute__((packed)) {
    int32_t *base;              // 0x00
    uint8_t  _pad08[0x08 - sizeof(int32_t *)];
    int32_t  cap;               // 0x08
    uint8_t  _pad0C[0x10 - 0x0C];
    int32_t  count;             // 0x10
} CUtlVecInt_t;

_Static_assert(offsetof(CUtlVecInt_t, cap)   == 0x08, "utlvec cap");
_Static_assert(offsetof(CUtlVecInt_t, count) == 0x10, "utlvec count");

// CPackageInfo
typedef struct __attribute__((packed)) {
    uint32_t     packageId;     // 0x00
    uint8_t      _pad04[0x40 - 0x04];
    CUtlVecInt_t apps;          // 0x40
    uint8_t      _pad54[0x58 - (0x40 + sizeof(CUtlVecInt_t))];
    CUtlVecInt_t depots;        // 0x58
} CPackageInfo_t;

_Static_assert(offsetof(CPackageInfo_t, packageId) == 0x00, "pkg id");
_Static_assert(offsetof(CPackageInfo_t, apps)      == 0x40, "pkg apps vec");
_Static_assert(offsetof(CPackageInfo_t, apps)   + offsetof(CUtlVecInt_t, count) == 0x50, "pkg apps count");
_Static_assert(offsetof(CPackageInfo_t, depots)    == 0x58, "pkg depots vec");
_Static_assert(offsetof(CPackageInfo_t, depots) + offsetof(CUtlVecInt_t, count) == 0x68, "pkg depots count");

#endif // MACSTEAM_STEAM_TYPES_H
