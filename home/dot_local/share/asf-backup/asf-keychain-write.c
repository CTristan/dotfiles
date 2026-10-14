#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#ifdef ASF_TEST_KEYCHAIN_PATH
#include <Security/SecKeychain.h>
#endif

enum {
    kExitFailure = 1,
    kExitDuplicate = 3,
    kMaximumSecretLength = 1024 * 1024
};

static volatile sig_atomic_t terminal_echo_disabled = 0;
static int terminal_input_fd = STDIN_FILENO;
static struct termios terminal_original;

static void restore_echo_for_signal(int signal_number) {
    if (terminal_echo_disabled) {
        (void)tcsetattr(terminal_input_fd, TCSAFLUSH, &terminal_original);
        (void)write(STDERR_FILENO, "\n", 1);
    }
    _exit(128 + signal_number);
}

static int install_terminal_signal_handlers(struct sigaction old_actions[3]) {
    const int signals[3] = {SIGINT, SIGTERM, SIGHUP};
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = restore_echo_for_signal;
    sigemptyset(&action.sa_mask);
    for (size_t index = 0; index < 3; index++) {
        if (sigaction(signals[index], &action, &old_actions[index]) != 0) {
            while (index > 0) {
                index--;
                (void)sigaction(signals[index], &old_actions[index], NULL);
            }
            return -1;
        }
    }
    return 0;
}

static void restore_terminal_signal_handlers(const struct sigaction old_actions[3]) {
    const int signals[3] = {SIGINT, SIGTERM, SIGHUP};
    for (size_t index = 0; index < 3; index++) {
        (void)sigaction(signals[index], &old_actions[index], NULL);
    }
}

static void erase_bytes(void *buffer, size_t length) {
    if (buffer != NULL && length > 0) {
        volatile unsigned char *cursor = buffer;
        while (length-- > 0) {
            *cursor++ = 0;
        }
    }
}

static int append_byte(unsigned char **buffer, size_t *length, size_t *capacity, unsigned char byte) {
    if (*length >= kMaximumSecretLength) {
        return -1;
    }
    if (*length == *capacity) {
        size_t next_capacity = (*capacity == 0) ? 256 : (*capacity * 2);
        if (next_capacity > kMaximumSecretLength) {
            next_capacity = kMaximumSecretLength;
        }
        unsigned char *next = realloc(*buffer, next_capacity);
        if (next == NULL) {
            return -1;
        }
        *buffer = next;
        *capacity = next_capacity;
    }
    (*buffer)[(*length)++] = byte;
    return 0;
}

static int read_secret(unsigned char **buffer, size_t *length) {
    size_t capacity = 0;
    int terminal_input = isatty(STDIN_FILENO);
    struct termios original;
    int echo_disabled = 0;
    struct sigaction old_actions[3];
    int handlers_installed = 0;

    if (terminal_input) {
        if (tcgetattr(STDIN_FILENO, &original) != 0) {
            return -1;
        }
        terminal_original = original;
        terminal_input_fd = STDIN_FILENO;
        if (install_terminal_signal_handlers(old_actions) != 0) {
            return -1;
        }
        handlers_installed = 1;
        struct termios hidden = original;
        hidden.c_lflag &= (tcflag_t)~ECHO;
        terminal_echo_disabled = 1;
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) != 0) {
            terminal_echo_disabled = 0;
            restore_terminal_signal_handlers(old_actions);
            return -1;
        }
        echo_disabled = 1;
        fputs("Passphrase: ", stderr);
        fflush(stderr);
    }

    int result = 0;
    for (;;) {
        unsigned char byte;
        ssize_t count = read(STDIN_FILENO, &byte, 1);
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            result = -1;
            break;
        }
        if (terminal_input && (byte == '\n' || byte == '\r')) {
            break;
        }
        if (append_byte(buffer, length, &capacity, byte) != 0) {
            result = -1;
            break;
        }
    }

    if (echo_disabled) {
        (void)tcsetattr(STDIN_FILENO, TCSAFLUSH, &original);
        terminal_echo_disabled = 0;
        fputc('\n', stderr);
        fflush(stderr);
    }
    if (handlers_installed) {
        restore_terminal_signal_handlers(old_actions);
    }
    if (result != 0) {
        erase_bytes(*buffer, capacity);
        free(*buffer);
        *buffer = NULL;
        *length = 0;
    }
    return result;
}

static int add_to_keychain(const unsigned char *secret, size_t length) {
    const char *account = getenv("USER");
    if (account == NULL || account[0] == '\0') {
        fputs("USER is unavailable; the ASF Keychain item was not added.\n", stderr);
        return kExitFailure;
    }
    if (length == 0 || length > (size_t)LONG_MAX) {
        fputs("The ASF backup passphrase is empty or too large.\n", stderr);
        return kExitFailure;
    }

    CFStringRef account_value = CFStringCreateWithCString(kCFAllocatorDefault, account, kCFStringEncodingUTF8);
    CFMutableDataRef secret_value = CFDataCreateMutable(kCFAllocatorDefault, (CFIndex)length);
    if (account_value == NULL || secret_value == NULL) {
        if (account_value != NULL) CFRelease(account_value);
        if (secret_value != NULL) CFRelease(secret_value);
        fputs("Could not prepare the ASF Keychain item.\n", stderr);
        return kExitFailure;
    }
    CFDataAppendBytes(secret_value, secret, (CFIndex)length);

    SecTrustedApplicationRef trusted_app = NULL;
    SecAccessRef access = NULL;
#ifdef ASF_TEST_KEYCHAIN_PATH
    SecKeychainRef test_keychain = NULL;
#endif
    OSStatus status = SecTrustedApplicationCreateFromPath("/usr/bin/security", &trusted_app);
    if (status == errSecSuccess) {
        const void *trusted_values[] = {trusted_app};
        CFArrayRef trusted_apps = CFArrayCreate(kCFAllocatorDefault, trusted_values, 1, &kCFTypeArrayCallBacks);
        if (trusted_apps == NULL) {
            status = errSecAllocate;
        } else {
            status = SecAccessCreate(CFSTR("ASF backup passphrase"), trusted_apps, &access);
            CFRelease(trusted_apps);
        }
    }

    CFMutableDictionaryRef item = NULL;
    if (status == errSecSuccess) {
        item = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                         &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
        if (item == NULL) {
            status = errSecAllocate;
        }
    }
#ifdef ASF_TEST_KEYCHAIN_PATH
    if (status == errSecSuccess) {
        status = SecKeychainOpen(ASF_TEST_KEYCHAIN_PATH, &test_keychain);
    }
#endif
    if (status == errSecSuccess) {
        CFStringRef service = CFSTR("asf-backup");
        CFStringRef label = CFSTR("ASF config backup passphrase");
        CFDictionarySetValue(item, kSecClass, kSecClassGenericPassword);
        CFDictionarySetValue(item, kSecAttrService, service);
        CFDictionarySetValue(item, kSecAttrAccount, account_value);
        CFDictionarySetValue(item, kSecAttrLabel, label);
        CFDictionarySetValue(item, kSecAttrAccess, access);
        CFDictionarySetValue(item, kSecValueData, secret_value);
#ifdef ASF_TEST_KEYCHAIN_PATH
        CFDictionarySetValue(item, kSecUseKeychain, test_keychain);
#endif
        status = SecItemAdd(item, NULL);
    }

    if (item != NULL) {
        CFDictionaryRemoveValue(item, kSecValueData);
        CFRelease(item);
    }
    if (CFDataGetLength(secret_value) > 0) {
        erase_bytes(CFDataGetMutableBytePtr(secret_value), (size_t)CFDataGetLength(secret_value));
    }
    CFRelease(secret_value);
    CFRelease(account_value);
    if (access != NULL) CFRelease(access);
    if (trusted_app != NULL) CFRelease(trusted_app);
#ifdef ASF_TEST_KEYCHAIN_PATH
    if (test_keychain != NULL) CFRelease(test_keychain);
#endif

    if (status == errSecDuplicateItem) {
        return kExitDuplicate;
    }
    if (status != errSecSuccess) {
        fprintf(stderr, "Could not add the ASF Keychain item (status %d).\n", (int)status);
        return kExitFailure;
    }
    return 0;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) {
        fputs("This writer accepts the passphrase only on stdin.\n", stderr);
        return kExitFailure;
    }

    unsigned char *secret = NULL;
    size_t length = 0;
    if (read_secret(&secret, &length) != 0) {
        fputs("Could not read the ASF backup passphrase.\n", stderr);
        return kExitFailure;
    }

    int result = add_to_keychain(secret, length);
    erase_bytes(secret, length);
    free(secret);
    return result;
}
