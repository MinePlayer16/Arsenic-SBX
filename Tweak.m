@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import <xpc/xpc.h>

#import <netinet/in.h>
#include <netinet/tcp.h>
#import <arpa/inet.h>
#include <pthread.h>

#define DARK_SWORD_TCP_PORT 28282
#define DARK_SWORD_TCP_ADDR "127.0.0.1"


typedef enum {
    OP_PING = 0,
    OP_ISSUE_EXTENSION = 1,
} ds_ipc_op_t;

typedef struct {
    uint32_t op;
    uint32_t padding;
    uint64_t address;
    uint64_t value;
    uint32_t size;
    uint32_t padding2;
} ds_ipc_request_t;

typedef struct {
    uint32_t status;
    uint32_t padding;
    uint64_t data;
} ds_ipc_response_t;

static int g_ipc_client_fd = -1;
static pthread_mutex_t g_ipc_lock = PTHREAD_MUTEX_INITIALIZER;

static bool safe_recv(int fd, void *buf, size_t len) {
    size_t total_received = 0;
    uint8_t *ptr = (uint8_t *)buf;
    while (total_received < len) {
        ssize_t n = recv(fd, ptr + total_received, len - total_received, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) {
            return false;
        }
        total_received += (size_t)n;
    }
    return true;
}

static bool safe_send(int fd, const void *buf, size_t len) {
    size_t total_sent = 0;
    const uint8_t *ptr = (const uint8_t *)buf;
    while (total_sent < len) {
        ssize_t n = send(fd, ptr + total_sent, len - total_sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) {
            return false;
        }
        total_sent += (size_t)n;
    }
    return true;
}

bool connect_to_arsenic(void) {
    if (g_ipc_client_fd >= 0) {
        return true;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[Tweak] socket() failed: %s (errno=%d)", strerror(errno), errno);
        return false;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(DARK_SWORD_TCP_PORT);
    addr.sin_addr.s_addr = inet_addr(DARK_SWORD_TCP_ADDR);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[Tweak] connect() to %s:%d failed: %s (errno=%d)", DARK_SWORD_TCP_ADDR, DARK_SWORD_TCP_PORT, strerror(errno), errno);
        close(fd);
        return false;
    }

    NSLog(@"[Tweak] Connected to Arsenic Server via loopback TCP!");
    g_ipc_client_fd = fd;
    return true;
}

int64_t sandbox_extension_consume(const char *extension_token);

int ArsenicServer(void) {
    if (!connect_to_arsenic()) {
        NSLog(@"[Tweak] FAILED to connect to %s! Is Arsenic Server enabled?\n", DARK_SWORD_TCP_ADDR);
        return -1;
    }
    return 0;
}


char* ds_issue_extension(pid_t pid) {
    pthread_mutex_lock(&g_ipc_lock);
    if (!connect_to_arsenic()) {
        pthread_mutex_unlock(&g_ipc_lock);
        return NULL;
    }
    
    ds_ipc_request_t req = { .op = OP_ISSUE_EXTENSION, .address = 0, .value = pid, .size = 0 };
    
    if (!safe_send(g_ipc_client_fd, &req, sizeof(req))) {
        pthread_mutex_unlock(&g_ipc_lock);
        return NULL;
    }

    ds_ipc_response_t resp;
    
    if (!safe_recv(g_ipc_client_fd, &resp, sizeof(resp))) {
        pthread_mutex_unlock(&g_ipc_lock);
        return NULL;
    }
    
    if (resp.status == (uint32_t)-1 || resp.data == 0) {
        pthread_mutex_unlock(&g_ipc_lock);
        return NULL;
    }
    
    char *token = malloc(resp.data);
    if (!safe_recv(g_ipc_client_fd, token, resp.data)) {
        free(token);
        pthread_mutex_unlock(&g_ipc_lock);
        return NULL;
    }
    
    pthread_mutex_unlock(&g_ipc_lock);
    return token;
}

int sbxescape(pid_t pid)
{
    pid_t app_pid = getpid();
    NSLog(@"[Tweak] Requesting root filesystem token for injected App (PID %d) via Arsenic Server...", app_pid);
    
    // sends a request for the token
    char *token = ds_issue_extension(app_pid);
    if (!token) {
        NSLog(@"[Tweak] Arsenic failed to issue sandbox token. Did it ran the exploit?");
        return -1;
    }
    
    NSLog(@"[Tweak] Received token from Arsenic: %s", token);
    
    // The app consumes its token
    int64_t handle = sandbox_extension_consume(token);
    free(token);
    
    if (handle < 0) {
        NSLog(@"[Tweak] sandbox_extension_consume failed.");
        return -1;
    }

    // verify it's working
    int fd = open("/var/mobile/.checksbx", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd); unlink("/var/mobile/.checksbx");
        NSLog(@"[Tweak] Sandbox already escaped");
        return 0;
    }

    NSLog(@"[Tweak] sandbox escape verification failed (errno=%d: %s)", errno, strerror(errno));
    return -1;
}

static void runTweak(void) {
    NSLog(@"[Tweak] Connecting to Arsenic Server...");
    int cret = ArsenicServer();
    if (cret != 0) {
        NSLog(@"[Tweak] Connection failed: %d", cret);
        return;
    }

    NSLog(@"[Tweak] Connection succeded, requesting sandbox token...");
    int sret = sbxescape(getpid());
    if (sret != 0) {
        NSLog(@"[Tweak] Sandbox escape failed");
        return;
    }
}

__attribute__((constructor)) void TweakInit(void) {

    // Check if sandbox is already escaped
    int fd = open("/var/mobile/.checksbx", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd); unlink("/var/mobile/.checksbx");
        NSLog(@"[Tweak] Sandbox already escaped");
        return;
    }

    // wait for app to finish launching
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            runTweak();
        });
    }];
}
