APP = blocks
SRC = main.m
CFLAGS = -Oz -DNDEBUG -fno-objc-arc -fno-stack-protector -fomit-frame-pointer -fvisibility=hidden -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Wno-unused-parameter
FRAMEWORKS = -framework Cocoa
LDFLAGS = -Wl,-dead_strip,-x

all: $(APP)

$(APP): $(SRC)
	xcrun clang $(CFLAGS) $(SRC) $(FRAMEWORKS) $(LDFLAGS) -o $(APP)
	strip -Sx $(APP)

run: $(APP)
	./$(APP)

clean:
	rm -f $(APP)

.PHONY: all run clean
