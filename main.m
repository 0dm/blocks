#import <Cocoa/Cocoa.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);

enum {
    FB_W = 320,
    FB_H = 200,
    WORLD_X = 64,
    WORLD_Y = 64,
    WORLD_Z = 64
};

static const float PLAYER_RADIUS = 0.22f;
static const float PLAYER_EYE = 1.55f;
static const float PLAYER_HEADROOM = 0.10f;
static const float GRAVITY = 22.0f;
static const float JUMP_VELOCITY = 8.0f;

typedef struct { float x, y, z; } Vec3;
typedef struct {
    BOOL hit;
    int x, y, z;
    int px, py, pz;
    int nx, ny, nz;
    uint8_t block;
    float distance;
} RayHit;

static uint8_t g_world[WORLD_X * WORLD_Y * WORLD_Z];

static inline int idx3(int x, int y, int z) {
    return x + y * WORLD_X + z * WORLD_X * WORLD_Y;
}

static inline BOOL inside(int x, int y, int z) {
    return x >= 0 && x < WORLD_X && y >= 0 && y < WORLD_Y && z >= 0 && z < WORLD_Z;
}

static inline uint8_t world_get(int x, int y, int z) {
    return inside(x, y, z) ? g_world[idx3(x, y, z)] : 0;
}

static inline void world_set(int x, int y, int z, uint8_t v) {
    if (inside(x, y, z)) g_world[idx3(x, y, z)] = v;
}

static inline float clampf1(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline uint8_t clamp_u8(float v) {
    return (uint8_t)clampf1(v, 0.0f, 255.0f);
}

static inline float fracf1(float v) {
    return v - floorf(v);
}

static inline float wrap_angle(float a) {
    const float tau = (float)(M_PI * 2.0);
    while (a < 0.0f) a += tau;
    while (a >= tau) a -= tau;
    return a;
}

static inline Vec3 v3(float x, float y, float z) { return (Vec3){ x, y, z }; }
static inline Vec3 vadd(Vec3 a, Vec3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
static inline Vec3 vsub(Vec3 a, Vec3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
static inline Vec3 vmul(Vec3 a, float s) { return v3(a.x * s, a.y * s, a.z * s); }
static inline float vdot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

static inline Vec3 vcross(Vec3 a, Vec3 b) {
    return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

static inline Vec3 vnorm(Vec3 a) {
    float m2 = vdot(a, a);
    if (m2 <= 0.000001f) return v3(0.0f, 0.0f, 0.0f);
    float inv = 1.0f / sqrtf(m2);
    return vmul(a, inv);
}

static inline uint32_t pack_rgb(uint8_t r, uint8_t g, uint8_t b) {
    return (255u << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

static void center_mouse(NSWindow *window) {
    NSRect frame = ((NSRect(*)(id,SEL))objc_msgSend)((id)window, sel_registerName("frame"));
    CGWarpMouseCursorPosition(CGPointMake(NSMidX(frame), NSMidY(frame)));
}

static void set_mouse_captured(NSWindow *window, BOOL *state, BOOL captured) {
    if (*state == captured) return;
    *state = captured;
    if (captured) {
        ((void(*)(id,SEL))objc_msgSend)((id)objc_getClass("NSCursor"), sel_registerName("hide"));
        CGAssociateMouseAndMouseCursorPosition(false);
        center_mouse(window);
    } else {
        CGAssociateMouseAndMouseCursorPosition(true);
        ((void(*)(id,SEL))objc_msgSend)((id)objc_getClass("NSCursor"), sel_registerName("unhide"));
    }
}

static BOOL player_clear(Vec3 eye) {
    float minX = eye.x - PLAYER_RADIUS;
    float maxX = eye.x + PLAYER_RADIUS;
    float minY = eye.y - PLAYER_EYE;
    float maxY = eye.y - PLAYER_HEADROOM;
    float minZ = eye.z - PLAYER_RADIUS;
    float maxZ = eye.z + PLAYER_RADIUS;

    int x0 = (int)floorf(minX), x1 = (int)floorf(maxX);
    int y0 = (int)floorf(minY), y1 = (int)floorf(maxY);
    int z0 = (int)floorf(minZ), z1 = (int)floorf(maxZ);

    for (int z = z0; z <= z1; ++z) {
        for (int y = y0; y <= y1; ++y) {
            for (int x = x0; x <= x1; ++x) {
                if (!inside(x, y, z) || world_get(x, y, z)) return NO;
            }
        }
    }
    return YES;
}

static BOOL player_grounded(Vec3 eye) {
    return !player_clear(v3(eye.x, eye.y - 0.07f, eye.z));
}

static void generate_world(void) {
    memset(g_world, 0, sizeof(g_world));
    for (int z = 0; z < WORLD_Z; ++z) {
        for (int x = 0; x < WORLD_X; ++x) {
            float ridges =
                7.0f * sinf(x * 0.11f) +
                6.0f * cosf(z * 0.09f) +
                4.0f * sinf((x + z) * 0.05f);
            float detail =
                2.5f * sinf(x * 0.37f) * cosf(z * 0.29f) +
                1.8f * sinf((x - z) * 0.17f);
            float terrain = 24.0f + ridges + detail;
            int top = (int)clampf1(terrain, 7.0f, WORLD_Y - 4.0f);

            for (int y = 0; y <= top; ++y) {
                uint8_t block = 3;
                if (y == top) block = 1;
                else if (y > top - 3) block = 2;
                if (y == 0) block = 4;

                float cave =
                    sinf(x * 0.27f) +
                    sinf(y * 0.31f) +
                    cosf(z * 0.23f) +
                    sinf((x + y + z) * 0.11f);
                if (y > 3 && y < top - 1 && cave > 2.2f) continue;

                world_set(x, y, z, block);
            }
        }
    }
}

static inline uint8_t tex_noise(int x, int y, int z) {
    return (uint8_t)((x * 17 + y * 31 + z * 13 + x * z * 3) & 15);
}

static float face_ao(RayHit hit) {
    int occ = 0;
    if (hit.ny != 0) {
        occ += world_get(hit.x - 1, hit.y, hit.z) != 0;
        occ += world_get(hit.x + 1, hit.y, hit.z) != 0;
        occ += world_get(hit.x, hit.y, hit.z - 1) != 0;
        occ += world_get(hit.x, hit.y, hit.z + 1) != 0;
    } else if (hit.nx != 0) {
        occ += world_get(hit.x, hit.y - 1, hit.z) != 0;
        occ += world_get(hit.x, hit.y + 1, hit.z) != 0;
        occ += world_get(hit.x, hit.y, hit.z - 1) != 0;
        occ += world_get(hit.x, hit.y, hit.z + 1) != 0;
    } else {
        occ += world_get(hit.x - 1, hit.y, hit.z) != 0;
        occ += world_get(hit.x + 1, hit.y, hit.z) != 0;
        occ += world_get(hit.x, hit.y - 1, hit.z) != 0;
        occ += world_get(hit.x, hit.y + 1, hit.z) != 0;
    }
    return 1.0f - 0.07f * (float)occ;
}

static BOOL raycast_world(Vec3 origin, Vec3 dir, float maxDist, RayHit *outHit) {
    int x = (int)floorf(origin.x);
    int y = (int)floorf(origin.y);
    int z = (int)floorf(origin.z);

    int prevX = x, prevY = y, prevZ = z;
    int stepX = dir.x > 0.0f ? 1 : -1;
    int stepY = dir.y > 0.0f ? 1 : -1;
    int stepZ = dir.z > 0.0f ? 1 : -1;

    const float inf = 1e30f;
    float tDeltaX = fabsf(dir.x) > 0.000001f ? fabsf(1.0f / dir.x) : inf;
    float tDeltaY = fabsf(dir.y) > 0.000001f ? fabsf(1.0f / dir.y) : inf;
    float tDeltaZ = fabsf(dir.z) > 0.000001f ? fabsf(1.0f / dir.z) : inf;

    float nextX = dir.x > 0.0f ? ((float)x + 1.0f - origin.x) : (origin.x - (float)x);
    float nextY = dir.y > 0.0f ? ((float)y + 1.0f - origin.y) : (origin.y - (float)y);
    float nextZ = dir.z > 0.0f ? ((float)z + 1.0f - origin.z) : (origin.z - (float)z);

    float tMaxX = fabsf(dir.x) > 0.000001f ? nextX * tDeltaX : inf;
    float tMaxY = fabsf(dir.y) > 0.000001f ? nextY * tDeltaY : inf;
    float tMaxZ = fabsf(dir.z) > 0.000001f ? nextZ * tDeltaZ : inf;

    int nx = 0, ny = 0, nz = 0;
    float t = 0.0f;

    for (int i = 0; i < 256 && t <= maxDist; ++i) {
        if (inside(x, y, z)) {
            uint8_t block = world_get(x, y, z);
            if (block) {
                outHit->hit = YES;
                outHit->x = x; outHit->y = y; outHit->z = z;
                outHit->px = prevX; outHit->py = prevY; outHit->pz = prevZ;
                outHit->nx = nx; outHit->ny = ny; outHit->nz = nz;
                outHit->block = block;
                outHit->distance = t;
                return YES;
            }
        }

        prevX = x; prevY = y; prevZ = z;
        if (tMaxX < tMaxY && tMaxX < tMaxZ) {
            x += stepX;
            t = tMaxX;
            tMaxX += tDeltaX;
            nx = -stepX; ny = 0; nz = 0;
        } else if (tMaxY < tMaxZ) {
            y += stepY;
            t = tMaxY;
            tMaxY += tDeltaY;
            nx = 0; ny = -stepY; nz = 0;
        } else {
            z += stepZ;
            t = tMaxZ;
            tMaxZ += tDeltaZ;
            nx = 0; ny = 0; nz = -stepZ;
        }
    }

    outHit->hit = NO;
    return NO;
}

static void block_color(RayHit hit, uint8_t *r, uint8_t *g, uint8_t *b) {
    uint8_t n = tex_noise(hit.x, hit.y, hit.z);
    switch (hit.block) {
        case 1:
            if (hit.ny > 0) {
                *r = (uint8_t)(92 + n);
                *g = (uint8_t)(154 + n * 2);
                *b = (uint8_t)(64 + (n >> 1));
            } else {
                *r = (uint8_t)(110 + n);
                *g = (uint8_t)(86 + (n >> 1));
                *b = (uint8_t)(56 + (n >> 2));
            }
            break;
        case 2:
            *r = (uint8_t)(108 + n);
            *g = (uint8_t)(80 + (n >> 1));
            *b = (uint8_t)(52 + (n >> 2));
            break;
        case 3:
            *r = (uint8_t)(108 + n * 2);
            *g = (uint8_t)(112 + n * 2);
            *b = (uint8_t)(118 + n * 2);
            break;
        case 4:
            *r = (uint8_t)(165 + n * 3);
            *g = (uint8_t)(70 + n);
            *b = (uint8_t)(42 + (n >> 1));
            break;
        default:
            *r = *g = *b = 0;
            break;
    }
}

static inline Vec3 camera_forward(float yaw, float pitch) {
    float cp = cosf(pitch);
    return vnorm(v3(cosf(yaw) * cp, sinf(pitch), sinf(yaw) * cp));
}

static void render_frame(uint32_t *pixels, Vec3 camera, float yaw, float pitch) {
    Vec3 forward = camera_forward(yaw, pitch);
    Vec3 upWorld = v3(0.0f, 1.0f, 0.0f);
    Vec3 right = vnorm(vcross(forward, upWorld));
    Vec3 up = vnorm(vcross(right, forward));
    Vec3 sunDir = vnorm(v3(-0.55f, 0.72f, 0.42f));

    float aspect = (float)FB_W / (float)FB_H;
    float fov = 0.90f;
    float scale = tanf(fov * 0.5f);

    for (int y = 0; y < FB_H; ++y) {
        float sy = (1.0f - 2.0f * (((float)y + 0.5f) / (float)FB_H)) * scale;
        for (int x = 0; x < FB_W; ++x) {
            float sx = (2.0f * (((float)x + 0.5f) / (float)FB_W) - 1.0f) * aspect * scale;
            Vec3 dir = vnorm(vadd(forward, vadd(vmul(right, sx), vmul(up, sy))));

            RayHit hit = {0};
            uint8_t r, g, b;
            if (raycast_world(camera, dir, 96.0f, &hit)) {
                block_color(hit, &r, &g, &b);

                Vec3 n = v3((float)hit.nx, (float)hit.ny, (float)hit.nz);
                float shade = 0.36f + 0.64f * clampf1(vdot(n, sunDir), 0.0f, 1.0f);
                shade *= face_ao(hit);

                Vec3 hp = vadd(camera, vmul(dir, hit.distance + 0.0005f));
                float fx = fracf1(hp.x), fy = fracf1(hp.y), fz = fracf1(hp.z);
                float u = hit.nx != 0 ? fz : fx;
                float v = hit.ny != 0 ? fz : fy;
                if (hit.nz != 0) { u = fx; v = fy; }
                float edge = fminf(fminf(u, 1.0f - u), fminf(v, 1.0f - v));
                shade *= clampf1(0.78f + edge * 4.5f, 0.78f, 1.0f);

                float fog = clampf1(1.0f - hit.distance / 90.0f, 0.0f, 1.0f);
                float rf = r * shade * fog + 78.0f * (1.0f - fog);
                float gf = g * shade * fog + 124.0f * (1.0f - fog);
                float bf = b * shade * fog + 186.0f * (1.0f - fog);
                pixels[y * FB_W + x] = pack_rgb(clamp_u8(rf), clamp_u8(gf), clamp_u8(bf));
            } else {
                float t = clampf1(0.5f + 0.5f * dir.y, 0.0f, 1.0f);
                float sun = clampf1(vdot(dir, sunDir), 0.0f, 1.0f);
                sun *= sun; sun *= sun; sun *= sun; sun *= sun; sun *= sun;
                r = clamp_u8(74.0f + 70.0f * t + 90.0f * sun);
                g = clamp_u8(122.0f + 78.0f * t + 70.0f * sun);
                b = clamp_u8(180.0f + 58.0f * t + 20.0f * sun);
                pixels[y * FB_W + x] = pack_rgb(r, g, b);
            }
        }
    }

    int cx = FB_W / 2;
    int cy = FB_H / 2;
    for (int i = -4; i <= 4; ++i) {
        pixels[cy * FB_W + (cx + i)] = pack_rgb(255, 255, 255);
        pixels[(cy + i) * FB_W + cx] = pack_rgb(255, 255, 255);
    }
}

static uint32_t *gPixels;
static CGContextRef gBitmap;
static CGColorSpaceRef gColorSpace;
static BOOL gKeys[256];
static Vec3 gCamera;
static float gYaw, gPitch, gVerticalVelocity;
static BOOL gMouseCaptured;
static uint8_t gSelectedBlock;
static CFTimeInterval gLastTick;
static Class gViewClass;

static SEL sAlloc, sInitWithFrame, sWindow, sFrame, sSetNeedsDisplay;
static SEL sKeyCode, sDeltaX, sDeltaY, sCurrentContext, sCGContext;
static SEL sSharedApplication, sSetActivationPolicy, sRun, sActivateIgnoringOtherApps;
static SEL sSetTitle, sSetContentView, sMakeFirstResponder, sSetAcceptsMouseMovedEvents, sMakeKeyAndOrderFront;
static SEL sScheduledTimer, sTerminate;
static SEL sAcceptsFirstResponder, sKeyDown, sKeyUp, sMouseDown, sRightMouseDown, sMouseMoved, sStep, sDrawRect;

#define M0(r,o,s) ((r(*)(id,SEL))objc_msgSend)((id)(o),(s))
#define M1(r,o,s,t,a) ((r(*)(id,SEL,t))objc_msgSend)((id)(o),(s),(a))
#define M2(r,o,s,t1,a1,t2,a2) ((r(*)(id,SEL,t1,t2))objc_msgSend)((id)(o),(s),(a1),(a2))
#define M3(r,o,s,t1,a1,t2,a2,t3,a3) ((r(*)(id,SEL,t1,t2,t3))objc_msgSend)((id)(o),(s),(a1),(a2),(a3))
#define M4(r,o,s,t1,a1,t2,a2,t3,a3,t4,a4) ((r(*)(id,SEL,t1,t2,t3,t4))objc_msgSend)((id)(o),(s),(a1),(a2),(a3),(a4))
#define M5(r,o,s,t1,a1,t2,a2,t3,a3,t4,a4,t5,a5) ((r(*)(id,SEL,t1,t2,t3,t4,t5))objc_msgSend)((id)(o),(s),(a1),(a2),(a3),(a4),(a5))

static id B_init(id self, SEL _cmd, NSRect frame) {
    struct objc_super sup = { self, class_getSuperclass(gViewClass) };
    self = ((id(*)(struct objc_super *, SEL, NSRect))objc_msgSendSuper)(&sup, sInitWithFrame, frame);
    if (!self) return nil;

    gPixels = calloc((size_t)FB_W * (size_t)FB_H, sizeof(uint32_t));
    gColorSpace = CGColorSpaceCreateDeviceRGB();
    gBitmap = CGBitmapContextCreate(gPixels, FB_W, FB_H, 8, FB_W * 4, gColorSpace,
                                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

    generate_world();
    gCamera = v3(32.5f, 38.0f, 32.5f);
    gYaw = 0.75f;
    gPitch = -0.25f;
    gVerticalVelocity = 0.0f;
    gSelectedBlock = 2;
    gLastTick = CFAbsoluteTimeGetCurrent();

    M5(id, (id)objc_getClass("NSTimer"), sScheduledTimer,
       double, 1.0 / 60.0, id, self, SEL, sStep, id, nil, BOOL, YES);
    return self;
}

static BOOL B_accepts(id self, SEL _cmd) { return YES; }

static void B_keyDown(id self, SEL _cmd, id e) {
    NSUInteger code = M0(NSUInteger, e, sKeyCode);
    if (code < 256) gKeys[code] = YES;
    if (code >= 18 && code <= 21) gSelectedBlock = (uint8_t)(code - 17);
    if (code == 53) {
        if (gMouseCaptured) set_mouse_captured(M0(id, self, sWindow), &gMouseCaptured, NO);
        else M1(void, M0(id, (id)objc_getClass("NSApplication"), sSharedApplication), sTerminate, id, nil);
    }
}

static void B_keyUp(id self, SEL _cmd, id e) {
    NSUInteger code = M0(NSUInteger, e, sKeyCode);
    if (code < 256) gKeys[code] = NO;
}

static void B_mouseDown(id self, SEL _cmd, id e) {
    if (!gMouseCaptured) {
        set_mouse_captured(M0(id, self, sWindow), &gMouseCaptured, YES);
        return;
    }
    RayHit hit = {0};
    Vec3 f = camera_forward(gYaw, gPitch);
    if (raycast_world(gCamera, f, 12.0f, &hit) && hit.block != 4) world_set(hit.x, hit.y, hit.z, 0);
}

static void B_rightMouseDown(id self, SEL _cmd, id e) {
    if (!gMouseCaptured) {
        set_mouse_captured(M0(id, self, sWindow), &gMouseCaptured, YES);
        return;
    }
    RayHit hit = {0};
    Vec3 f = camera_forward(gYaw, gPitch);
    if (raycast_world(gCamera, f, 12.0f, &hit) && inside(hit.px, hit.py, hit.pz) && !world_get(hit.px, hit.py, hit.pz))
        world_set(hit.px, hit.py, hit.pz, gSelectedBlock);
}

static void B_mouseMoved(id self, SEL _cmd, id e) {
    if (!gMouseCaptured) return;
    gYaw = wrap_angle(gYaw + (float)M0(CGFloat, e, sDeltaX) * 0.0025f);
    gPitch = clampf1(gPitch - (float)M0(CGFloat, e, sDeltaY) * 0.0025f, -1.4f, 1.4f);
    center_mouse(M0(id, self, sWindow));
}

static void B_step(id self, SEL _cmd) {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    float dt = clampf1((float)(now - gLastTick), 0.0f, 0.033f);
    gLastTick = now;

    if (gKeys[123]) gYaw -= 1.8f * dt;
    if (gKeys[124]) gYaw += 1.8f * dt;
    if (gKeys[126]) gPitch += 1.8f * dt;
    if (gKeys[125]) gPitch -= 1.8f * dt;
    gYaw = wrap_angle(gYaw);
    gPitch = clampf1(gPitch, -1.4f, 1.4f);

    Vec3 forward = camera_forward(gYaw, gPitch);
    Vec3 flatForward = vnorm(v3(forward.x, 0.0f, forward.z));
    Vec3 right = vnorm(vcross(flatForward, v3(0.0f, 1.0f, 0.0f)));

    Vec3 move = v3(0.0f, 0.0f, 0.0f);
    if (gKeys[13]) move = vadd(move, flatForward);
    if (gKeys[1])  move = vsub(move, flatForward);
    if (gKeys[0])  move = vsub(move, right);
    if (gKeys[2])  move = vadd(move, right);

    Vec3 next = gCamera;
    if (vdot(move, move) > 0.0f) {
        Vec3 delta = vmul(vnorm(move), ((gKeys[56] || gKeys[60]) ? 8.8f : 5.4f) * dt);
        Vec3 test = next;
        test.x += delta.x;
        if (player_clear(test)) next.x = test.x;
        test = next;
        test.z += delta.z;
        if (player_clear(test)) next.z = test.z;
    }

    if ((gKeys[49] || gKeys[14]) && player_grounded(next)) gVerticalVelocity = JUMP_VELOCITY;
    gVerticalVelocity -= GRAVITY * dt;
    if (gVerticalVelocity < -18.0f) gVerticalVelocity = -18.0f;

    Vec3 test = next;
    test.y += gVerticalVelocity * dt;
    if (player_clear(test)) next.y = test.y;
    else gVerticalVelocity = 0.0f;

    if (player_grounded(next) && gVerticalVelocity <= 0.0f) gVerticalVelocity = 0.0f;
    gCamera = next;

    render_frame(gPixels, gCamera, gYaw, gPitch);
    M1(void, self, sSetNeedsDisplay, BOOL, YES);
}

static void B_drawRect(id self, SEL _cmd, NSRect dirty) {
    id gc = M0(id, (id)objc_getClass("NSGraphicsContext"), sCurrentContext);
    CGContextRef cg = M0(CGContextRef, gc, sCGContext);
    CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
    CGImageRef image = CGBitmapContextCreateImage(gBitmap);
    CGContextDrawImage(cg, NSRectToCGRect(M0(NSRect, self, sFrame)), image);
    CGImageRelease(image);
}

int main(int argc, const char *argv[]) {
    void *pool = objc_autoreleasePoolPush();
    sAlloc = sel_registerName("alloc");
    sInitWithFrame = sel_registerName("initWithFrame:");
    sWindow = sel_registerName("window");
    sFrame = sel_registerName("frame");
    sSetNeedsDisplay = sel_registerName("setNeedsDisplay:");
    sKeyCode = sel_registerName("keyCode");
    sDeltaX = sel_registerName("deltaX");
    sDeltaY = sel_registerName("deltaY");
    sCurrentContext = sel_registerName("currentContext");
    sCGContext = sel_registerName("CGContext");
    sSharedApplication = sel_registerName("sharedApplication");
    sSetActivationPolicy = sel_registerName("setActivationPolicy:");
    sRun = sel_registerName("run");
    sActivateIgnoringOtherApps = sel_registerName("activateIgnoringOtherApps:");
    sSetTitle = sel_registerName("setTitle:");
    sSetContentView = sel_registerName("setContentView:");
    sMakeFirstResponder = sel_registerName("makeFirstResponder:");
    sSetAcceptsMouseMovedEvents = sel_registerName("setAcceptsMouseMovedEvents:");
    sMakeKeyAndOrderFront = sel_registerName("makeKeyAndOrderFront:");
    sScheduledTimer = sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:");
    sTerminate = sel_registerName("terminate:");
    sAcceptsFirstResponder = sel_registerName("acceptsFirstResponder");
    sKeyDown = sel_registerName("keyDown:");
    sKeyUp = sel_registerName("keyUp:");
    sMouseDown = sel_registerName("mouseDown:");
    sRightMouseDown = sel_registerName("rightMouseDown:");
    sMouseMoved = sel_registerName("mouseMoved:");
    sStep = sel_registerName("step");
    sDrawRect = sel_registerName("drawRect:");

    gViewClass = objc_allocateClassPair((Class)objc_getClass("NSView"), "B", 0);
    class_addMethod(gViewClass, sInitWithFrame, (IMP)B_init, "@@:");
    class_addMethod(gViewClass, sAcceptsFirstResponder, (IMP)B_accepts, "B@:");
    class_addMethod(gViewClass, sKeyDown, (IMP)B_keyDown, "v@:@");
    class_addMethod(gViewClass, sKeyUp, (IMP)B_keyUp, "v@:@");
    class_addMethod(gViewClass, sMouseDown, (IMP)B_mouseDown, "v@:@");
    class_addMethod(gViewClass, sRightMouseDown, (IMP)B_rightMouseDown, "v@:@");
    class_addMethod(gViewClass, sMouseMoved, (IMP)B_mouseMoved, "v@:@");
    class_addMethod(gViewClass, sStep, (IMP)B_step, "v@:");
    class_addMethod(gViewClass, sDrawRect, (IMP)B_drawRect, "v@:");
    objc_registerClassPair(gViewClass);

    id app = M0(id, (id)objc_getClass("NSApplication"), sSharedApplication);
    M1(void, app, sSetActivationPolicy, NSInteger, NSApplicationActivationPolicyRegular);

    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    id window = M0(id, (id)objc_getClass("NSWindow"), sAlloc);
    window = M4(id, window, sel_registerName("initWithContentRect:styleMask:backing:defer:"),
                NSRect, NSMakeRect(160, 120, 960, 600), NSUInteger, style,
                NSUInteger, NSBackingStoreBuffered, BOOL, NO);
    id title = M1(id, (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), const char *, "Blocks");
    id view = M1(id, M0(id, (id)gViewClass, sAlloc), sInitWithFrame, NSRect, NSMakeRect(0, 0, 960, 600));

    M1(void, window, sSetTitle, id, title);
    M1(void, window, sSetContentView, id, view);
    M1(void, window, sMakeFirstResponder, id, view);
    M1(void, window, sSetAcceptsMouseMovedEvents, BOOL, YES);
    M1(void, window, sMakeKeyAndOrderFront, id, nil);
    M1(void, app, sActivateIgnoringOtherApps, BOOL, YES);
    M0(void, app, sRun);

    objc_autoreleasePoolPop(pool);
    return 0;
}
