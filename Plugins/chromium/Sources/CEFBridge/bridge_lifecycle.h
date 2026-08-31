// Copyright (c) 2026 Andreas Pihlstrom
// SPDX-License-Identifier: MIT
//
// CEF-independent browser lifecycle state. Keeping this state separate makes
// asynchronous create/close ordering deterministic and directly testable.

#ifndef CMDY_CEF_BRIDGE_LIFECYCLE_H
#define CMDY_CEF_BRIDGE_LIFECYCLE_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <set>
#include <vector>

namespace cmdy::cef_bridge {

enum class BrowserCreatedAction {
    accept,
    closeImmediately,
    unknownHandle,
};

enum class BrowserCloseAction {
    closeBrowser,
    waitForCreation,
    alreadyClosing,
    unknownHandle,
};

class BrowserLifecycleRegistry final {
public:
    intptr_t reserve() {
        const intptr_t handle = nextHandle_++;
        entries_.emplace(handle, Entry{});
        return handle;
    }

    bool cancelCreation(intptr_t handle) {
        const auto iterator = entries_.find(handle);
        if (iterator == entries_.end() ||
            iterator->second.phase != Phase::creating) {
            return false;
        }
        entries_.erase(iterator);
        return true;
    }

    BrowserCreatedAction didCreate(intptr_t handle) {
        const auto iterator = entries_.find(handle);
        if (iterator == entries_.end()) {
            return BrowserCreatedAction::unknownHandle;
        }
        if (iterator->second.phase != Phase::creating) {
            return iterator->second.phase == Phase::closing
                ? BrowserCreatedAction::closeImmediately
                : BrowserCreatedAction::accept;
        }
        if (iterator->second.closeRequested) {
            iterator->second.phase = Phase::closing;
            return BrowserCreatedAction::closeImmediately;
        }
        iterator->second.phase = Phase::live;
        return BrowserCreatedAction::accept;
    }

    BrowserCloseAction requestClose(intptr_t handle) {
        const auto iterator = entries_.find(handle);
        if (iterator == entries_.end()) {
            return BrowserCloseAction::unknownHandle;
        }
        switch (iterator->second.phase) {
        case Phase::creating:
            if (iterator->second.closeRequested) {
                return BrowserCloseAction::alreadyClosing;
            }
            iterator->second.closeRequested = true;
            return BrowserCloseAction::waitForCreation;
        case Phase::live:
            iterator->second.closeRequested = true;
            iterator->second.phase = Phase::closing;
            return BrowserCloseAction::closeBrowser;
        case Phase::closing:
            return BrowserCloseAction::alreadyClosing;
        }
    }

    bool didClose(intptr_t handle) {
        return entries_.erase(handle) == 1;
    }

    std::vector<intptr_t> handles() const {
        std::vector<intptr_t> result;
        result.reserve(entries_.size());
        for (const auto& [handle, _] : entries_) {
            result.push_back(handle);
        }
        return result;
    }

    std::size_t size() const { return entries_.size(); }
    bool empty() const { return entries_.empty(); }

private:
    enum class Phase {
        creating,
        live,
        closing,
    };

    struct Entry {
        Phase phase = Phase::creating;
        bool closeRequested = false;
    };

    intptr_t nextHandle_ = 1;
    std::map<intptr_t, Entry> entries_;
};

/// Tracks secondary CEF browsers (currently DevTools) whose creation does not
/// return a synchronous handle. Shutdown must wait for both pending creates and
/// every OnBeforeClose callback.
class AuxiliaryBrowserLifecycle final {
public:
    void beginCreate() { ++pendingCreates_; }

    void didCreate(int browserIdentifier) {
        if (pendingCreates_ > 0) --pendingCreates_;
        liveIdentifiers_.insert(browserIdentifier);
    }

    bool didClose(int browserIdentifier) {
        return liveIdentifiers_.erase(browserIdentifier) == 1;
    }

    std::size_t pendingCount() const { return pendingCreates_; }
    std::size_t liveCount() const { return liveIdentifiers_.size(); }
    bool empty() const {
        return pendingCreates_ == 0 && liveIdentifiers_.empty();
    }

private:
    std::size_t pendingCreates_ = 0;
    std::set<int> liveIdentifiers_;
};

}  // namespace cmdy::cef_bridge

#endif  // CMDY_CEF_BRIDGE_LIFECYCLE_H
