//
//  AIChatView+Send.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, sending: whether the composer can send or enqueue, waiting for
//  voice recognition to finish before sending, and performEnqueue /
//  performSend.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

private let minisLogger = AppLogger(category: "MinisURL")

extension AIChatView {
    var canSend: Bool {
        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ready = vm.isReady
        // [T-ios-photo-pick-placeholder] Block sending while any picked photo is
        // still loading. Only count `.ready` attachments as sendable content, so
        // a composer holding ONLY failed/loading chips (and no text) can't send.
        let hasReadyAttachment = vm.attachments.contains { $0.loadState == .ready }
        return ready && !vm.hasLoadingAttachments && (hasText || hasReadyAttachment || voiceOwesText)
    }

    var canEnqueue: Bool {
        vm.isProcessing && (!vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceOwesText)
    }

    /// [T-voice-send-waits-for-asr] Voice mode has captured speech that is not
    /// text yet. Send must be tappable then — tapping it is how the user says
    /// "I'm done" — even though the composer may still be empty.
    private var voiceOwesText: Bool {
        voiceInputActive && (voiceVM.hasUntranscribedAudio || voiceVM.isFinishingForSend)
    }

    /// [T-voice-send-lock] Send was tapped and the message is on its way, but
    /// not out yet: the mic is being stopped and recognition has to finish
    /// first. The send button shows this as busy and takes no taps - and only
    /// for this: every way the wait can end (sent, failed, timed out,
    /// cancelled, text edited, recording restarted, voice mode or the chat
    /// left) clears `isFinishingForSend` in one place, VoiceInputViewModel's
    /// `concludeFinishForSend`.
    var isWaitingToSendVoice: Bool {
        voiceInputActive && voiceVM.isFinishingForSend
    }

    /// [T-voice-send-waits-for-asr] If voice input still owes text, stop the
    /// mic, let every captured sample finish recognition, then come back
    /// through `submitAfterVoice` to send (or queue). Returns true when the
    /// send was deferred and the caller must stop.
    ///
    /// The completion captures only the action channel, never this view (see
    /// ComposerActionChannel for why that matters).
    private func deferSendUntilVoiceFinished() -> Bool {
        guard voiceInputActive,
              voiceVM.hasUntranscribedAudio || voiceVM.isFinishingForSend else { return false }
        voiceVM.finishCaptureForSend { [composerActions] ok in
            if ok { composerActions.send(.submitAfterVoice) }
        }
        return true
    }

    /// [T-voice-send-waits-for-asr] Second half of a deferred voice send. The
    /// transcript reaches `inputText` through a SwiftUI onChange, i.e. on a
    /// later render, so copy the final transcript over explicitly before
    /// deciding what to do; then send or queue exactly as the tap would have.
    ///
    /// [T-voice-send-lock] This runs once per wait (VoiceSendGate), and what it
    /// starts must not wait again: `afterVoice` skips the deferral, so a
    /// capture that would not stop, or audio that arrived in the meantime,
    /// cannot turn one tap into a second wait and a second send. Whether there
    /// is anything to send is decided by what the composer holds NOW, not by
    /// "voice still owes text" - recognition can come back empty.
    func submitAfterVoice() {
        guard voiceInputActive else {
            minisLogger.info("[voice-send] recognition finished after voice mode was left — not sending")
            return
        }
        let transcript = voiceVM.transcript
        if !transcript.isEmpty, vm.inputText != transcript {
            vm.inputText = transcript
        }
        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyAttachment = vm.attachments.contains { $0.loadState == .ready }
        if vm.isProcessing && hasText {
            performEnqueue(afterVoice: true)
        } else if vm.isReady && !vm.hasLoadingAttachments && (hasText || hasReadyAttachment) {
            performSend(afterVoice: true)
        } else {
            minisLogger.info("[voice-send] nothing to send after recognition finished (text=\(hasText) attachment=\(hasReadyAttachment) ready=\(vm.isReady))")
        }
    }

    /// Whether the composer actually holds something worth moving to another
    /// session — non-blank text or at least one attachment. Gates the
    /// "Move to…" pill so it never appears over an empty composer.
    var hasMovableShareContent: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !vm.attachments.isEmpty
    }


    /// `afterVoice`: the call that follows a finished voice wait (see
    /// `submitAfterVoice`) - it must not start another one.
    func performEnqueue(afterVoice: Bool = false) {
        if !afterVoice, deferSendUntilVoiceFinished() { return }
        // Dismiss the software keyboard on enqueue. With a hardware keyboard,
        // keep focus so the user can continue typing the next candidate.
        if GCKeyboard.coalesced == nil {
            inputFocused = false
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        vm.forceScrollToBottom.send()
        if speechManager.state == .recording {
            speechManager.stopRecording()
        }
        speechManager.recognizedText = ""
        lastRecognizedLength = 0
        vm.enqueuePrompt()
        // [inline-voice] Enqueue consumed the text — clear the voice transcript
        // too, otherwise it lingers in the panel (the "residual after swipe-send"
        // bug). performSend already does this; the enqueue path (taken while the
        // agent is processing) was missing it.
        if voiceInputActive {
            voiceVM.clearAndRearm()
        }
    }

    /// Dismiss keyboard (commit dictation/marked text) before sending.
    func performSend(afterVoice: Bool = false) {
        if !afterVoice, deferSendUntilVoiceFinished() { return }
        // Intercept slash commands — execute instead of sending to LLM
        if vm.tryExecuteInputAsSlashCommand() { return }

        // [T-optimize-prompt] Auto-pick-fastest / auto-switch-unavailable run
        // BEFORE the turn is built (they may switch the session's bound model).
        // They need a real session id (a draft has none) and do async work, so
        // we run them in a @MainActor Task that then performs the actual send.
        Task { @MainActor in
            await self.ensureSessionThenApplyAutoRules()
            self.performSendNow(afterVoice: afterVoice)
        }
    }

    /// The synchronous half of `performSend` — runs after the auto-rules have
    /// been applied (and a session id exists). Mirrors the original body.
    @MainActor
    private func performSendNow(afterVoice: Bool = false) {
        minisLogger.info("🔑DRAFT performSend vm=\(vm.vmInstanceId) vm.sessionId=\(vm.sessionId ?? "nil") draftId=\(draftId ?? "nil") inputText='\(String(vm.inputText.prefix(50)))' isProcessing=\(vm.isProcessing)")
        // Keep SwiftUI focus when a hardware keyboard is connected — dropping
        // it would force the user to tap the field again before typing the
        // next message. With only the software keyboard, clear focus and
        // dismiss it so the @FocusState binding stays in sync.
        let hasHardwareKeyboard = GCKeyboard.coalesced != nil
        if !hasHardwareKeyboard {
            inputFocused = false
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // User actively sending — force scroll-to-bottom so the response scrolls into view
        vm.forceScrollToBottom.send()
        // Stop recording and clear recognized text so it doesn't linger after send
        if speechManager.state == .recording {
            speechManager.stopRecording()
        }
        speechManager.recognizedText = ""
        lastRecognizedLength = 0
        hasInjectedShareContent = false
        // Send FIRST while inputText still holds the recognized text. Clearing the
        // voice transcript here (clearAndRearm) mirrors "" into inputText via the
        // onChange binding, so doing it before send() left send() with empty text
        // → "send() GUARD FAILED" and nothing was sent. send() consumes and clears
        // inputText itself; we re-arm voice listening only AFTER it has run.
        vm.send()
        // [T-optimize-prompt] Auto-retry if no first token arrives within 10s.
        if autoRetryOnTimeout {
            scheduleAutoRetryIfStalled()
        }
        // [T-auto-switch-on-error] Immediately watch for a send error (404 model
        // missing, rate limit, etc.) and switch to another model — independent of
        // the 10s stall timer and its toggle.
        if ChatOptimizer.shared.autoSwitchUnavailableEnabled {
            watchForSendErrorAndSwitch()
            watchForMessageErrorAndSwitch()
        }
        // [inline-voice] Stay in voice mode after sending — clear the recognized
        // text and re-arm listening for the next utterance (close with ✕).
        if voiceInputActive {
            voiceVM.clearAndRearm()
        }
    }

    /// [T-optimize-prompt] Ensure a real session exists, then apply the
    /// auto-pick-fastest / auto-switch-unavailable rules before the turn is
    /// built. Only mutates the binding when a rule actually fires; the VM's
    /// `resolveCurrentEntry` cache re-resolves because `setBinding` bumps
    /// `configRevision`. Must run on @MainActor (everything here is).
    @MainActor
    private func ensureSessionThenApplyAutoRules() async {
        // A draft has no session id yet. `vm.ensureSession()` lazily creates one
        // (draft→real) and writes the initial binding. Without it, OpenCode-family
        // channels would 400 on the first turn anyway, and applyAutoRules needs a
        // session id to read/switch the binding.
        if vm.sessionId == nil {
            await vm.ensureSession()
        }
        guard let sid = vm.sessionId, !sid.isEmpty else {
            AppLogger(category: "ChatOptimizer").warning("[autoRules] no session id after ensureSession — skipping")
            return
        }
        _ = await ChatOptimizer.shared.applyAutoRules(sessionId: sid)
    }

    /// [T-optimize-prompt] After a send, wait `timeoutSeconds`; then either retry
    /// (stalled) or, if the turn ended in an error, auto-switch to another model
    /// and retry (when `autoSwitchUnavailable` is on).
    @MainActor
    private func scheduleAutoRetryIfStalled() {
        let timeout = ChatOptimizerSettings.timeoutSeconds
        Task { [weak vm] in
            guard let vm = vm else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Has the assistant produced a real (non-error) reply?
            let last = vm.messages.last
            let hasText = last?.role == .assistant &&
                (last?.blocks.contains { $0.kind == .text && !$0.content.isEmpty } ?? false)
            let isError = (last?.role == .assistant) && Self.looksLikeError(last)
            // Stalled (still processing, no text) → plain retry.
            if vm.isProcessing, !hasText {
                AppLogger(category: "ChatOptimizer").info("[autoRetry] no first token in \(Int(timeout))s — retrying")
                vm.retry()
                return
            }
            // Turn ended in an error → if auto-switch is on, swap model and retry.
            if isError, ChatOptimizer.shared.autoSwitchUnavailableEnabled,
               let sid = vm.sessionId, !sid.isEmpty {
                if ChatOptimizer.shared.switchToNextAvailable(sessionId: sid) {
                    AppLogger(category: "ChatOptimizer").info("[autoSwitch] on failure — switched and retrying")
                    vm.retry()
                    return
                }
            }
        }
    }

    /// Heuristic: does this assistant message look like an error (e.g. backend
    /// 404 "model not found") rather than a real reply?
    private static func looksLikeError(_ message: ChatMessage?) -> Bool {
        guard let message = message else { return false }
        let joined = message.blocks.compactMap { $0.kind == .text ? $0.content : nil }
            .joined(separator: " ")
        // [T-auto-switch-markers] Cover every provider error wording, including
        // rate limiting ("Rate limited — please try again later" has no
        // "Provider error" prefix) and the various 404 model-missing phrasings.
        // Also inspect the row's `error` field — the "额度已用完" banner lands
        // there, not in a text block.
        let text = joined + " " + (message.error ?? "")
        let markers = ["Provider error", "[404]", "Rate limited", "rate limit",
                       "模型不存在", "未启用", "not found", "not enabled",
                       "does not exist", "model is not", "Service temporarily unavailable",
                       "Invalid API key", "额度已用完", "quota", "quota exceeded"]
        return markers.contains { text.contains($0) }
    }

    /// [T-auto-switch-on-error] Poll `vm.errorMessage` right after a send; the
    /// first time it becomes non-nil, switch the session to another available
    /// model and retry once. Stops after one switch so it cannot loop forever.
    @MainActor
    /// [T-auto-switch-on-error] Poll until the turn ends (or ~5 min), then do a
    /// FINAL error check. Provider errors (404 / Rate limited) are written into
    /// the assistant row's text blocks, not always to vm.errorMessage — so we
    /// match all three sources: vm.errorMessage, the row's `error` field, and
    /// the row's block text via `looksLikeError`. On a hit, switch model + retry
    /// once (no loop). Independent of the 10s stall timer and its toggle.
    private func watchForSendErrorAndSwitch() {
        watchForErrorAndSwitch(useRowText: false)
    }

    /// [T-auto-switch-on-error] Watch per-message error (rate-limit / provider
    /// errors land on the assistant row, not always on vm.errorMessage).
    @MainActor
    private func watchForMessageErrorAndSwitch() {
        watchForErrorAndSwitch(useRowText: true)
    }

    private func watchForErrorAndSwitch(useRowText: Bool) {
        Task { [weak vm] in
            guard let vm = vm else { return }
            // [T-any-error-switch] Keep switching on ANY red-banner error until a
            // model answers or we run out of candidates. Each failure switches to
            // the next model and retries, so a quota-exhausted model falls through
            // to the next one automatically — no keyword matching needed.
            let maxSwitches = 3
            var switchCount = 0
            while switchCount < maxSwitches {
                var gracePollsLeft = 40   // 40 * 250ms = 10s grace after turn end
                var err: String? = nil
                for _ in 0..<1200 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                    err = self.currentErrorText(vm: vm, useRowText: useRowText)
                    if err != nil { break }
                    if !vm.isProcessing {
                        if gracePollsLeft > 0 { gracePollsLeft -= 1; continue }
                        return   // turn over cleanly, no error → done
                    }
                }
                guard let theError = err,
                      ChatOptimizer.shared.autoSwitchUnavailableEnabled,
                      let sid = vm.sessionId, !sid.isEmpty else { return }

                AppLogger(category: "ChatOptimizer").warning("[autoSwitch] error: \(theError.prefix(120)) — switching model and retrying")
                let switchedModel = ChatOptimizer.shared.switchToNextAvailable(sessionId: sid)
                vm.errorMessage = nil
                // Clear the error on the assistant row that actually holds it
                // (messages.last can be a queued user row).
                for idx in vm.messages.indices where vm.messages[idx].role == .assistant {
                    vm.messages[idx].error = nil
                }
                if !switchedModel {
                    // No other model to switch to — retry the CURRENT model once
                    // (the error may be transient), then stop.
                    AppLogger(category: "ChatOptimizer").warning("[autoSwitch] no replacement available; retrying current model once")
                }
                switchCount += 1
                // vm.retry() early-returns while isProcessing is true, so wait
                // for the failed turn to fully settle before re-sending.
                for _ in 0..<40 {
                    if !vm.isProcessing { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                }
                vm.retry()
                // Loop again to watch the retried turn for a further failure.
            }
        }
    }

    /// Unified error-source reader: vm.errorMessage, then the LAST ASSISTANT
    /// row's `error` field. [T-any-error-switch] The red banner is the ONLY
    /// authority: `reportTurnFailure` sets `carrier.error` (and clears it only
    /// on a successful follow-up), so a non-nil `error` means the turn failed —
    /// we switch models on ANY such error, no keyword matching. The assistant
    /// row is resolved with `last(where: role == .assistant)` because
    /// `messages.last` can be a queued user row appended mid-tool.
    private func currentErrorText(vm: AIChatViewModel, useRowText: Bool) -> String? {
        if let e = vm.errorMessage, !e.isEmpty { return e }
        let lastAssistant = vm.messages.last(where: { $0.role == .assistant })
        if let err = lastAssistant?.error, !err.isEmpty { return err }
        // Fallback: the error may live in the row's text block (some provider
        // paths write "Provider error: ..." into the assistant text instead of
        // the error field). Only treat it as an error if the row ALSO ended the
        // turn with no streaming content — i.e. it really is a failure row, not
        // a healthy reply.
        if useRowText, let last = lastAssistant,
           last.blocks.contains(where: { if case .text = $0.kind { return true }; return false }),
           last.error == nil {
            return Self.looksLikeError(last) ? "assistant row error" : nil
        }
        return nil
    }
}
