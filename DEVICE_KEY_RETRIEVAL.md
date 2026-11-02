# How we retrieved the band's authentication key

This records the procedure that worked on 2026-11-02 for a Xiaomi Smart Band 7
NFC paired with Zepp Life 6.16.1 on an Android 15 phone. Vendor login flows can
change; this is a record of the tested workflow.

The result was a 16-byte authentication key, stored as 32 hexadecimal digits in
`~/.config/smart-band/auth-key.hex`. The actual key and account credentials are
not included in this document.

## 1. Connect the phone over USB

We enabled Developer options and USB debugging on the phone, connected it by
cable, and accepted the debugging authorization prompt for the computer.

```sh
adb devices -l
```

The phone appeared with status `device`, confirming authorized ADB access.
ADB allowed us to inspect app information and navigate the phone's screens.

We checked whether Zepp Life's private app data was accessible:

```sh
adb shell run-as com.xiaomi.hm.health id
```

Android returned `package not debuggable`. No root utility was available either.
Consequently, we used account-based retrieval. We did not extract Zepp Life's
private database. USB debugging alone did not grant access to that database.

## 2. Link the existing Zepp Life profile to a Xiaomi account

Zepp Life's Settings screen showed that its current login method was Google.
Under **Profile → Settings → Account and security**, **Mi Account** showed **Add**.

We opened **Mi Account → Add**. The owner used Xiaomi's **Forgot password** flow
to recover access to the existing Xiaomi account, completing the CAPTCHA,
email verification, and password reset on the phone.

We then returned to Zepp Life and reopened **Mi Account → Add**. Xiaomi presented
an **Agree and link** screen. In this session, it bundled five permissions:

- Xiaomi Account information
- Mi Home/Xiaomi Home services
- Mi Pay services
- Xiaomi Pay services
- Mi AI voice assistant

The owner explicitly approved these permissions. After linking, we reopened
**Account and security** and verified that **Mi Account** now showed **Unpair**.
The existing band pairing remained in place throughout this procedure.

## 3. Authorize a browser session for cloud retrieval

Linking the account did not itself export the key. We used the browser
authorization flow documented by [huafetcher](https://codeberg.org/vanous/huafetcher).
Its public OAuth parameters were:

| Parameter | Value |
| --- | --- |
| Authorization endpoint | `https://account.xiaomi.com/oauth2/authorize` |
| `client_id` | `2882303761517383915` |
| `redirect_uri` | `https://hm.xiaomi.com/watch.do` |
| `response_type` | `code` |
| `scope` | `1 6000 16001 20000` |
| `skip_confirm` | `false` |
| `pt` | `0` |
| `_locale` | `en_US` |

We opened this authorization flow in Chrome on the phone. Chrome offered a saved
credential for the matching Xiaomi account. We used its sign-in prompt without
displaying or copying the password. Xiaomi then required email verification;
the owner entered the verification code on the phone and completed sign-in.

The browser redirected to a URL of this form:

```text
https://hm.xiaomi.com/watch.do?code=REDACTED
```

The callback URL contained a sensitive authorization code. We captured it locally
from Chrome's accessible UI using ADB and a temporary UI XML snapshot. It was
processed in a private temporary directory, without printing the code in chat.

## 4. Exchange the authorization code and request the device key

We prepared a temporary Node.js helper using the protocol described in
huafetcher's [`urls.py`](https://codeberg.org/vanous/huafetcher/src/branch/master/urls.py)
and [`huami_token.py`](https://codeberg.org/vanous/huafetcher/src/branch/master/huami_token.py).
It used Node's built-in APIs and required no installed JavaScript packages.

The helper performed these steps:

1. Read the authorization code from the local UI snapshot.
2. Submit a form request to `https://account.huami.com/v2/client/login` using
   `third_name=mi-watch`, `grant_type=request_token`, the authorization `code`,
   and the client metadata used by the reference flow. It set
   `allow_registration=false` and generated a temporary client device identifier.
3. Read `app_token`, `login_token`, and `user_id` from the returned `token_info`.
4. Request `/users/{user_id}/devices` from the vendor's device API, passing the
   `app_token` in the `apptoken` HTTP header. The helper used a vendor-provided
   regional hostname when available, with known Huami/Zepp hostnames as fallbacks.
   It restricted these requests to the expected vendor domains.
5. Match the returned device's `macAddress` against the band address in our local
   configuration. This avoided choosing another device associated with the account.
6. Parse that device's `additionalInfo` and read its `auth_key` field.
7. Require exactly 32 hexadecimal digits before saving the key.

This retrieved the existing key held by the vendor's backend. We did not derive
it from the Bluetooth address or generate a replacement key.

The temporary helper was used only for setup. It was removed afterward and is
not included in this repository or required by the Zig program at runtime.
To repeat the account-based approach, consult the linked reference project;
the temporary helper cannot be rerun from this repository.

## 5. Save the key privately and clean up

The helper created this file with owner-only permissions (`0600`):

```text
~/.config/smart-band/auth-key.hex
```

We verified that it was a regular file containing one valid 16-byte hexadecimal
key, without displaying the key. The helper logged out its temporary retrieval
session using `https://account-us2.huami.com/v1/client/logout`. We removed the
temporary phone UI dump, the local snapshot containing the callback code, and
the helper itself.

The Zig tool finds `auth-key.hex` beside the selected config by default. An
explicit path can be configured at the root of `config.zon`:

```zig
.auth_key_file = "auth-key.hex",
```

Relative key paths resolve beside the config file. Keep the key, passwords,
verification codes, and authorization callback URLs outside version control.

## 6. Verify the key against the band

After implementing native Huami 2021 authentication in the Zig tool, we ran:

```sh
./zig-out/bin/smart-band notify "Desktop icon test 2"
```

The band accepted the key and completed the authentication handshake. After
adding the app-icon upload required by the band, the owner confirmed that a
notification appeared. A second notification over a fresh Bluetooth connection
also appeared with the message `Build finished — repeat test`. This verified
that the retrieved key worked with the actual band.

See [README.md](README.md) for the current notification commands and configuration.

## Background reference

[Gadgetbridge's Huami/Xiaomi pairing guide](https://gadgetbridge.org/basics/pairing/huami-xiaomi-server/)
describes server-based key retrieval and the separate rooted-phone database
method. Account-based retrieval depends on the relevant backend holding the
device's key; the successful result above applies to our tested account and band.
