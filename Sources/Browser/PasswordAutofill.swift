import AppKit
import WebKit

/// A sign-in the page's top frame submitted over HTTPS, offered for saving.
struct PasswordCapture: Equatable {
    let origin: PasswordOrigin
    let username: String
    let password: String

    var account: SavedPassword {
        SavedPassword(origin: origin, username: username)
    }

    /// Accepts only what the autofill script sends from a page's top frame, with the origin taken from WebKit
    /// rather than from anything the page could set.
    init?(body: Any, isMainFrame: Bool, origin: PasswordOrigin?) {
        guard isMainFrame, let origin, let body = body as? [String: Any], body["type"] as? String == "submit",
              let password = body["password"] as? String, !password.isEmpty, password.count <= 1024,
              let username = body["username"] as? String, username.count <= 512 else { return nil }
        self.origin = origin
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }
}

/// Watches sign-in forms from a content world of the app's own, which page scripts can't see or reach. It reports
/// the credentials a form submits, and that the page has a password field so the browser can offer to fill it.
@MainActor
enum PasswordAutofill {
    static let world = WKContentWorld.world(name: "BrowserPasswords")
    static let handlerName = "browserPasswords"

    /// Only for normal windows; a private window's pages never load the script.
    static func install(in controller: WKUserContentController, handler: WKScriptMessageHandler) {
        // WebKit-provided popup configurations can share their opener's content controller.
        guard !controller.userScripts.contains(where: { $0.source == script }) else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                              in: world))
        controller.add(handler, contentWorld: world, name: handlerName)
    }

    static let script = """
    (() => {
      const handler = window.webkit?.messageHandlers?.\(handlerName);
      if (!handler || window.top !== window) return;
      const passwordFields = (root) => [...root.querySelectorAll('input[type=password]')].filter((field) => !field.disabled);
      const usernameField = (root, password) => {
        const inputs = [...root.querySelectorAll('input')];
        const before = inputs.slice(0, inputs.indexOf(password)).reverse()
          .filter((input) => !input.disabled && ['text', 'email', 'tel', ''].includes(input.type));
        return before.find((input) => /username|email/.test(input.autocomplete)) ?? before[0] ?? null;
      };
      const credentials = (root) => {
        const filled = passwordFields(root).filter((field) => field.value);
        const password = filled.find((field) => field.autocomplete === 'new-password') ?? filled[0];
        if (!password) return null;
        return { username: usernameField(root, password)?.value ?? '', password: password.value };
      };
      let lastSent = null;
      const send = (root) => {
        // Never scan the whole page because an unrelated button was clicked or Return was pressed in search.
        if (!(root instanceof HTMLFormElement)) return;
        const found = credentials(root);
        if (!found) return;
        const key = found.username + '\\n' + found.password;
        if (key === lastSent) return;
        lastSent = key;
        handler.postMessage({ type: 'submit', ...found });
      };
      document.addEventListener('submit', (event) => send(event.target), true);
      // Some form-backed sign-in pages handle clicks or Return without submitting the form.
      document.addEventListener('click', (event) => {
        // Buttons with type="button" usually show the password or switch the form, rather than sign in.
        const button = event.target.closest?.('button, input[type=submit]');
        if (!button || button.type !== 'submit') return;
        const form = button.form ?? button.closest('form');
        if (form && form.checkValidity()) send(form);
      }, true);
      document.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' && event.target instanceof HTMLInputElement
            && event.target.form?.checkValidity()) send(event.target.form);
      }, true);
      const announce = () => {
        if (!passwordFields(document).length) return false;
        handler.postMessage({ type: 'fields' });
        return true;
      };
      if (!announce()) {
        const observer = new MutationObserver(() => { if (announce()) observer.disconnect(); });
        observer.observe(document, { childList: true, subtree: true });
      }
    })();
    """

    /// Fills the first password field and its user name field, only if the page is still on the password's origin.
    /// Setting the values from this world bypasses page frameworks' value tracking, so they see the input events.
    static let fillScript = """
    if (window.top !== window || location.origin !== origin) return false;
    const passwords = [...document.querySelectorAll('input[type=password]')]
      .filter((field) => !field.disabled && !field.readOnly && field.getClientRects().length
        && field.autocomplete !== 'new-password');
    const password = passwords.find((field) => field.autocomplete === 'current-password') ?? passwords[0];
    if (!password) return false;
    const root = password.form ?? document;
    const inputs = [...root.querySelectorAll('input')];
    const before = inputs.slice(0, inputs.indexOf(password)).reverse()
      .filter((input) => !input.disabled && ['text', 'email', 'tel', ''].includes(input.type));
    const user = before.find((input) => /username|email/.test(input.autocomplete)) ?? before[0];
    const fill = (field, value) => {
      field.focus();
      field.value = value;
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (user && username) fill(user, username);
    fill(password, secret);
    return true;
    """

    /// Fills a saved password into the tab's page, after the user picked it. Nothing fills unless the page shows
    /// exactly the password's origin, both before and after reading the keychain.
    static func supports(_ tab: BrowserTab) -> Bool {
        tab.profileID == BrowserProfile.defaultID && tab.browser?.isPrivate == false
    }

    static func fill(_ account: SavedPassword, in tab: BrowserTab, from passwords: PasswordManager) async {
        guard supports(tab), let webView = tab.webView, PasswordOrigin(url: webView.url) == account.origin else { return }
        guard let secret = passwords.password(for: account) else {
            await showFailure(passwords.lastError ?? "This saved password is no longer available.", in: tab)
            return
        }
        guard PasswordOrigin(url: webView.url) == account.origin else { return }
        do {
            let filled = try await webView.callAsyncJavaScript(fillScript, arguments: [
                "origin": account.origin.description, "username": account.username, "secret": secret,
            ], in: nil, contentWorld: world)
            if filled as? Bool != true {
                await showFailure("The page no longer has an editable sign-in field for this password.", in: tab)
            }
        } catch {
            await showFailure("The page couldn’t be filled. Try again after it finishes loading.", in: tab)
        }
    }

    private static func showFailure(_ message: String, in tab: BrowserTab) async {
        let alert = NSAlert()
        alert.messageText = "Couldn’t Fill Password"
        alert.informativeText = message
        _ = await tab.present(alert)
    }
}

/// Receives the autofill script's messages for one window's pages, including its pop-ups, which share their
/// opener's content controller.
@MainActor
final class PasswordMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var browser: BrowserModel?

    init(browser: BrowserModel) {
        self.browser = browser
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == PasswordAutofill.world, let browser, !browser.isPrivate,
              let webView = message.webView, let tab = browser.tab(for: webView),
              PasswordAutofill.supports(tab),
              let passwords = browser.passwordsForDefaultProfile else { return }
        if (message.body as? [String: Any])?["type"] as? String == "fields" {
            guard message.frameInfo.isMainFrame, PasswordOrigin(message.frameInfo.securityOrigin) != nil else { return }
            passwords.loadIfNeeded()
            tab.hasPasswordFields = true
            return
        }
        guard let capture = PasswordCapture(body: message.body, isMainFrame: message.frameInfo.isMainFrame,
                                            origin: PasswordOrigin(message.frameInfo.securityOrigin)),
              let proposal = passwords.reserveSaveOffer(for: capture) else { return }
        Task {
            defer { passwords.releaseSaveOffer(for: capture.account) }
            await ask(proposal, capture, in: tab, passwords: passwords)
        }
    }

    private func ask(_ proposal: PasswordManager.SaveProposal, _ capture: PasswordCapture, in tab: BrowserTab,
                     passwords: PasswordManager) async {
        guard await tab.waitUntilSelected(), passwords.saveProposal(for: capture) == proposal else { return }
        let site = capture.origin.host
        let alert = NSAlert()
        switch proposal.offer {
        case .save:
            alert.messageText = "Save your password for “\(site)”?"
            alert.informativeText = "Browser keeps it in your keychain, and can fill it in when you sign in to "
                + "this site again. You can see it in Settings ▸ Passwords."
            alert.addButton(withTitle: "Save Password")
        case .update:
            alert.messageText = capture.username.isEmpty ? "Update your saved password for “\(site)”?"
                : "Update the saved password for “\(capture.username)” on “\(site)”?"
            alert.addButton(withTitle: "Update Password")
        }
        alert.addButton(withTitle: "Not Now")
        if proposal.offer == .save { alert.addButton(withTitle: "Never for This Website") }
        switch await tab.present(alert) {
        case .alertFirstButtonReturn?:
            do { try passwords.save(capture, ifUnchanged: proposal) }
            catch {
                let failure = NSAlert()
                failure.messageText = "Couldn’t Save Password"
                failure.informativeText = passwords.lastError ?? error.localizedDescription
                _ = await tab.present(failure)
            }
        case .alertThirdButtonReturn?: passwords.neverSave(on: capture.origin)
        default: break
        }
    }
}
