// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <objc/message.h>

#import "FlutterEmbedderKeyResponder.h"
#import "KeyCodeMap_internal.h"
#import "flutter/shell/platform/darwin/common/framework/Headers/FlutterCodecs.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterViewController_Internal.h"
#import "flutter/shell/platform/embedder/embedder.h"

namespace {

/**
 * Isolate the least significant 1-bit.
 *
 * For example,
 *
 *  * lowestSetBit(0x1010) returns 0x10.
 *  * lowestSetBit(0) returns 0.
 */
static NSUInteger lowestSetBit(NSUInteger bitmask) {
  // This utilizes property of two's complement (negation), which propagates a
  // carry bit from LSB to the lowest set bit.
  return bitmask & -bitmask;
}

/**
 * Whether a string represents a control character.
 */
static bool IsControlCharacter(NSUInteger length, NSString* label) {
  if (length > 1) {
    return false;
  }
  unichar codeUnit = [label characterAtIndex:0];
  return (codeUnit <= 0x1f && codeUnit >= 0x00) || (codeUnit >= 0x7f && codeUnit <= 0x9f);
}

/**
 * Whether a string represents an unprintable key.
 */
static bool IsUnprintableKey(NSUInteger length, NSString* label) {
  if (length > 1) {
    return false;
  }
  unichar codeUnit = [label characterAtIndex:0];
  return codeUnit >= 0xF700 && codeUnit <= 0xF8FF;
}

/**
 * Returns a key code composed with a base key and a plane.
 *
 * Examples of unprintable keys are "NSUpArrowFunctionKey = 0xF700" or
 * "NSHomeFunctionKey = 0xF729".
 *
 * See
 * https://developer.apple.com/documentation/appkit/1535851-function-key_unicodes?language=objc
 * for more information.
 */
static uint64_t KeyOfPlane(uint64_t baseKey, uint64_t plane) {
  return plane | (baseKey & kValueMask);
}

/**
 * Returns the physical key for a key code.
 */
static uint64_t GetPhysicalKeyForKeyCode(unsigned short keyCode) {
  NSNumber* physicalKey = [keyCodeToPhysicalKey objectForKey:@(keyCode)];
  if (physicalKey == nil)
    return 0;
  return physicalKey.unsignedLongLongValue;
}

/**
 * Returns the logical key for a modifier physical key.
 */
static uint64_t GetLogicalKeyForModifier(unsigned short keyCode, uint64_t hidCode) {
  NSNumber* fromKeyCode = [keyCodeToLogicalKey objectForKey:@(keyCode)];
  if (fromKeyCode != nil)
    return fromKeyCode.unsignedLongLongValue;
  return KeyOfPlane(hidCode, kHidPlane);
}

/**
 * Converts upper letters to lower letters in ASCII, and returns as-is
 * otherwise.
 *
 * Independent of locale.
 */
static uint64_t toLower(uint64_t ch) {
  const uint64_t lowerA = 0x61;
  const uint64_t upperA = 0x41;
  const uint64_t upperZ = 0x5a;
  if (ch >= upperA && ch <= upperZ)
    return ch + (lowerA - upperA);
  return ch;
}

/**
 * Returns the logical key of a KeyUp or KeyDown event.
 *
 * For FlagsChanged event, use GetLogicalKeyForModifier.
 */
static uint64_t GetLogicalKeyForEvent(NSEvent* event, uint64_t physicalKey) {
  // Look to see if the keyCode can be mapped from keycode.
  NSNumber* fromKeyCode = [keyCodeToLogicalKey objectForKey:@(event.keyCode)];
  if (fromKeyCode != nil)
    return fromKeyCode.unsignedLongLongValue;

  NSString* keyLabel = event.charactersIgnoringModifiers;
  NSUInteger keyLabelLength = [keyLabel length];
  // If this key is printable, generate the logical key from its Unicode
  // value. Control keys such as ESC, CTRL, and SHIFT are not printable. HOME,
  // DEL, arrow keys, and function keys are considered modifier function keys,
  // which generate invalid Unicode scalar values.
  if (keyLabelLength != 0 && !IsControlCharacter(keyLabelLength, keyLabel) &&
      !IsUnprintableKey(keyLabelLength, keyLabel)) {
    // Given that charactersIgnoringModifiers can contain a string of arbitrary
    // length, limit to a maximum of two Unicode scalar values. It is unlikely
    // that a keyboard would produce a code point bigger than 32 bits, but it is
    // still worth defending against this case.
    NSCAssert((keyLabelLength < 2), @"Unexpected long key label: |%@|.", keyLabel);

    uint64_t codeUnit = (uint64_t)[keyLabel characterAtIndex:0];
    if (keyLabelLength == 2) {
      uint64_t secondCode = (uint64_t)[keyLabel characterAtIndex:1];
      codeUnit = (codeUnit << 16) | secondCode;
    }
    return KeyOfPlane(toLower(codeUnit), kUnicodePlane);
  }

  // Control keys like "backspace" and movement keys like arrow keys don't have
  // a printable representation, but are present on the physical keyboard. Since
  // there is no logical keycode map for macOS (macOS uses the keycode to
  // reference physical keys), a LogicalKeyboardKey is created with the physical
  // key's HID usage and debugName. This avoids duplicating the physical key
  // map.
  if (physicalKey != 0) {
    return KeyOfPlane(physicalKey, kHidPlane);
  }

  // This is a non-printable key that is unrecognized, so a new code is minted
  // with the autogenerated bit set.
  return KeyOfPlane(event.keyCode, kMacosPlane | kAutogeneratedMask);
}

/**
 * Converts NSEvent.timestamp to the timestamp for Flutter.
 */
static double GetFlutterTimestampFrom(NSTimeInterval timestamp) {
  // Timestamp in microseconds. The event.timestamp is in seconds with sub-ms precision.
  return timestamp * 1000000.0;
}

/**
 * Compute |modifierFlagOfInterestMask| out of |keyCodeToModifierFlag|.
 *
 * This is equal to the bitwise-or of all values of |keyCodeToModifierFlag| as
 * well as NSEventModifierFlagCapsLock.
 */
static NSUInteger computeModifierFlagOfInterestMask() {
  __block NSUInteger modifierFlagOfInterestMask = NSEventModifierFlagCapsLock;
  [keyCodeToModifierFlag
      enumerateKeysAndObjectsUsingBlock:^(NSNumber* keyCode, NSNumber* flag, BOOL* stop) {
        modifierFlagOfInterestMask = modifierFlagOfInterestMask | [flag unsignedLongValue];
      }];
  return modifierFlagOfInterestMask;
}

/**
 * The C-function sent to the embedder's |SendKeyEvent|, wrapping
 * |FlutterEmbedderKeyResponder.handleResponse|.
 *
 * For the reason of this wrap, see |FlutterKeyPendingResponse|.
 */
void HandleResponse(bool handled, void* user_data);

/**
 * Converts NSEvent.characters to a C-string for FlutterKeyEvent.
 */
const char* getEventString(NSString* characters) {
  if ([characters length] == 0) {
    return nullptr;
  }
  unichar utf16Code = [characters characterAtIndex:0];
  if (utf16Code >= 0xf700 && utf16Code <= 0xf7ff) {
    // Some function keys are assigned characters with codepoints from the
    // private use area. These characters are filtered out since they're
    // unprintable.
    //
    // The official documentation reserves 0xF700-0xF8FF as private use area
    // (https://developer.apple.com/documentation/appkit/1535851-function-key_unicodes?language=objc).
    // But macOS seems to only use a reduced range of it. The official doc
    // defines a few constants, all of which are within 0xF700-0xF747.
    // (https://developer.apple.com/documentation/appkit/1535851-function-key_unicodes?language=objc).
    // This mostly aligns with the experimentation result, except for 0xF8FF,
    // which is used for the "Apple logo" character (Option-Shift-K on a US
    // keyboard.)
    //
    // We hereby assume that non-printable function keys are defined from
    // 0xF700 upwards, and printable private keys are defined from 0xF8FF
    // downwards. We want to keep the printable private keys, therefore we only
    // filter out 0xF700-0xF7FF.
    return nullptr;
  }
  return [characters UTF8String];
}
}  // namespace

/**
 * The invocation context for |HandleResponse|, wrapping
 * |FlutterEmbedderKeyResponder.handleResponse|.
 *
 * The embedder functions only accept C-functions as callbacks, as well as an
 * arbitray user_data. In order to send an instance method of
 * |FlutterEmbedderKeyResponder.handleResponse| to the engine's |SendKeyEvent|,
 * we wrap the invocation into a C-function |HandleResponse| and invocation
 * context |FlutterKeyPendingResponse|.
 *
 * When this object is sent to the engine's |SendKeyEvent| as |user_data|, it
 * must be attached with |__bridge_retained|. When this object is parsed
 * in |HandleResponse| from |user_data|, it will be attached with
 * |__bridge_transfer|.
 */
@interface FlutterKeyPendingResponse : NSObject

@property(nonatomic) FlutterEmbedderKeyResponder* responder;

@property(nonatomic) uint64_t responseId;

- (nonnull instancetype)initWithHandler:(nonnull FlutterEmbedderKeyResponder*)responder
                             responseId:(uint64_t)responseId;

@end

@implementation FlutterKeyPendingResponse
- (instancetype)initWithHandler:(FlutterEmbedderKeyResponder*)responder
                     responseId:(uint64_t)responseId {
  self = [super init];
  if (self != nil) {
    _responder = responder;
    _responseId = responseId;
  }
  return self;
}
@end

/**
 * Guards a |FlutterAsyncKeyCallback| to make sure it's handled exactly once
 * throughout |FlutterEmbedderKeyResponder.handleEvent|.
 *
 * A callback can either be handled with |pendTo:withId:|, or with |resolveTo:|.
 * Either way, the callback can not be handled again, or an assertion will be
 * thrown.
 */
@interface FlutterKeyCallbackGuard : NSObject
- (nonnull instancetype)initWithCallback:(FlutterAsyncKeyCallback)callback;

/**
 * Handle the callback by storing it to pending responses.
 */
- (void)pendTo:(nonnull NSMutableDictionary<NSNumber*, FlutterAsyncKeyCallback>*)pendingResponses
        withId:(uint64_t)responseId;

/**
 * Handle the callback by calling it with a result.
 */
- (void)resolveTo:(BOOL)handled;

@property(nonatomic) BOOL handled;
/**
 * A string indicating how the callback is handled.
 *
 * Only set in debug mode. Nil in release mode, or if the callback has not been
 * handled.
 */
@property(nonatomic) NSString* debugHandleSource;
@end

@implementation FlutterKeyCallbackGuard {
  // The callback is declared in the implemnetation block to avoid being
  // accessed directly.
  FlutterAsyncKeyCallback _callback;
}
- (nonnull instancetype)initWithCallback:(FlutterAsyncKeyCallback)callback {
  self = [super init];
  if (self != nil) {
    _callback = callback;
    _handled = FALSE;
  }
  return self;
}

- (void)pendTo:(nonnull NSMutableDictionary<NSNumber*, FlutterAsyncKeyCallback>*)pendingResponses
        withId:(uint64_t)responseId {
  NSAssert(!_handled, @"This callback has been handled by %@.", _debugHandleSource);
  if (_handled) {
    return;
  }
  pendingResponses[@(responseId)] = _callback;
  _handled = TRUE;
  NSAssert(
      ((_debugHandleSource = [NSString stringWithFormat:@"pending event %llu", responseId]), TRUE),
      @"");
}

- (void)resolveTo:(BOOL)handled {
  NSAssert(!_handled, @"This callback has been handled by %@.", _debugHandleSource);
  if (_handled) {
    return;
  }
  _callback(handled);
  _handled = TRUE;
  NSAssert(((_debugHandleSource = [NSString stringWithFormat:@"resolved with %d", _handled]), TRUE),
           @"");
}
@end

@interface FlutterEmbedderKeyResponder ()

/**
 * The function to send converted events to.
 *
 * Set by the initializer.
 */
@property(nonatomic, copy) FlutterSendEmbedderKeyEvent sendEvent;

/**
 * A map of presessd keys.
 *
 * The keys of the dictionary are physical keys, while the values are the logical keys
 * of the key down event.
 */
@property(nonatomic) NSMutableDictionary<NSNumber*, NSNumber*>* pressingRecords;

/**
 * A constant mask for NSEvent.modifierFlags that Flutter synchronizes with.
 *
 * Flutter keeps track of the last |modifierFlags| and compares it with the
 * incoming one. Any bit within |modifierFlagOfInterestMask| that is different
 * (except for the one that corresponds to the event key) indicates that an
 * event for this modifier was missed, and Flutter synthesizes an event to make
 * up for the state difference.
 *
 * It is computed by computeModifierFlagOfInterestMask.
 */
@property(nonatomic) NSUInteger modifierFlagOfInterestMask;

/**
 * The modifier flags of the last received key event, excluding uninterested
 * bits.
 *
 * This should be kept synchronized with the last |NSEvent.modifierFlags|
 * after masking with |modifierFlagOfInterestMask|. This should also be kept
 * synchronized with the corresponding keys of |pressingRecords|.
 *
 * This is used by |synchronizeModifiers| to quickly find
 * out modifier keys that are desynchronized.
 */
@property(nonatomic) NSUInteger lastModifierFlagsOfInterest;

/**
 * A self-incrementing ID used to label key events sent to the framework.
 */
@property(nonatomic) uint64_t responseId;

/**
 * A map of unresponded key events sent to the framework.
 *
 * Its values are |responseId|s, and keys are the callback that was received
 * along with the event.
 */
@property(nonatomic) NSMutableDictionary<NSNumber*, FlutterAsyncKeyCallback>* pendingResponses;

/**
 * Compare the last modifier flags and the current, and dispatch synthesized
 * key events for each different modifier flag bit.
 *
 * The flags compared are all flags after masking with
 * |modifierFlagOfInterestMask| and excluding |ignoringFlags|.
 */
- (void)synchronizeModifiers:(NSUInteger)currentFlags
               ignoringFlags:(NSUInteger)ignoringFlags
                   timestamp:(NSTimeInterval)timestamp;

/**
 * Update the pressing state.
 *
 * If `logicalKey` is not 0, `physicalKey` is pressed as `logicalKey`.
 * Otherwise, `physicalKey` is released.
 */
- (void)updateKey:(uint64_t)physicalKey asPressed:(uint64_t)logicalKey;

/**
 * Send an event to the framework, expecting its response.
 */
- (void)sendPrimaryFlutterEvent:(const FlutterKeyEvent&)event
                       callback:(nonnull FlutterKeyCallbackGuard*)callback;

/**
 * Send a CapsLock down event, then a CapsLock up event.
 *
 * If downCallback is nil, then both events will be synthesized. Otherwise, the
 * downCallback will be used as the callback for the down event, which is not
 * synthesized.
 */
- (void)sendCapsLockTapWithTimestamp:(NSTimeInterval)timestamp
                            callback:(nullable FlutterKeyCallbackGuard*)downCallback;

/**
 * Send a key event for a modifier key.
 *
 * If callback is nil, then the event is synthesized.
 */
- (void)sendModifierEventOfType:(BOOL)isDownEvent
                      timestamp:(NSTimeInterval)timestamp
                        keyCode:(unsigned short)keyCode
                       callback:(nullable FlutterKeyCallbackGuard*)callback;

/**
 * Processes a down event from the system.
 */
- (void)handleDownEvent:(nonnull NSEvent*)event callback:(nonnull FlutterKeyCallbackGuard*)callback;

/**
 * Processes an up event from the system.
 */
- (void)handleUpEvent:(nonnull NSEvent*)event callback:(nonnull FlutterKeyCallbackGuard*)callback;

/**
 * Processes an event from the system for the CapsLock key.
 */
- (void)handleCapsLockEvent:(nonnull NSEvent*)event
                   callback:(nonnull FlutterKeyCallbackGuard*)callback;

/**
 * Processes a flags changed event from the system, where modifier keys are pressed or released.
 */
- (void)handleFlagEvent:(nonnull NSEvent*)event callback:(nonnull FlutterKeyCallbackGuard*)callback;

/**
 * Processes the response from the framework.
 */
- (void)handleResponse:(BOOL)handled forId:(uint64_t)responseId;

@end

@implementation FlutterEmbedderKeyResponder

- (nonnull instancetype)initWithSendEvent:(FlutterSendEmbedderKeyEvent)sendEvent {
  self = [super init];
  if (self != nil) {
    _sendEvent = sendEvent;
    _pressingRecords = [NSMutableDictionary dictionary];
    _pendingResponses = [NSMutableDictionary dictionary];
    _responseId = 1;
    _lastModifierFlagsOfInterest = 0;
    _modifierFlagOfInterestMask = computeModifierFlagOfInterestMask();
  }
  return self;
}

- (void)handleEvent:(NSEvent*)event callback:(FlutterAsyncKeyCallback)callback {
  // The conversion algorithm relies on a non-nil callback to properly compute
  // `synthesized`.
  NSAssert(callback != nil, @"The callback must not be nil.");
  FlutterKeyCallbackGuard* guardedCallback =
      [[FlutterKeyCallbackGuard alloc] initWithCallback:callback];
  switch (event.type) {
    case NSEventTypeKeyDown:
      [self handleDownEvent:event callback:guardedCallback];
      break;
    case NSEventTypeKeyUp:
      [self handleUpEvent:event callback:guardedCallback];
      break;
    case NSEventTypeFlagsChanged:
      [self handleFlagEvent:event callback:guardedCallback];
      break;
    default:
      NSAssert(false, @"Unexpected key event type: |%@|.", @(event.type));
  }
  NSAssert(guardedCallback.handled, @"The callback is returned without being handled.");
  NSAssert(_lastModifierFlagsOfInterest == (event.modifierFlags & _modifierFlagOfInterestMask),
           @"The modifier flags are not properly updated: recorded 0x%lx, event with mask 0x%lx",
           _lastModifierFlagsOfInterest, event.modifierFlags & _modifierFlagOfInterestMask);
}

#pragma mark - Private

- (void)synchronizeModifiers:(NSUInteger)currentFlags
               ignoringFlags:(NSUInteger)ignoringFlags
                   timestamp:(NSTimeInterval)timestamp {
  const NSUInteger updatingMask = _modifierFlagOfInterestMask & ~ignoringFlags;
  const NSUInteger currentFlagsOfInterest = currentFlags & updatingMask;
  const NSUInteger lastFlagsOfInterest = _lastModifierFlagsOfInterest & updatingMask;
  NSUInteger flagDifference = currentFlagsOfInterest ^ lastFlagsOfInterest;
  if (flagDifference & NSEventModifierFlagCapsLock) {
    [self sendCapsLockTapWithTimestamp:timestamp callback:nil];
    flagDifference = flagDifference & ~NSEventModifierFlagCapsLock;
  }
  while (true) {
    const NSUInteger currentFlag = lowestSetBit(flagDifference);
    if (currentFlag == 0) {
      break;
    }
    flagDifference = flagDifference & ~currentFlag;
    NSNumber* keyCode = [modifierFlagToKeyCode objectForKey:@(currentFlag)];
    NSAssert(keyCode != nil, @"Invalid modifier flag 0x%lx", currentFlag);
    if (keyCode == nil) {
      continue;
    }
    BOOL isDownEvent = (currentFlagsOfInterest & currentFlag) != 0;
    [self sendModifierEventOfType:isDownEvent
                        timestamp:timestamp
                          keyCode:[keyCode unsignedShortValue]
                         callback:nil];
  }
  _lastModifierFlagsOfInterest =
      (_lastModifierFlagsOfInterest & ~updatingMask) | currentFlagsOfInterest;
}

- (void)updateKey:(uint64_t)physicalKey asPressed:(uint64_t)logicalKey {
  if (logicalKey == 0) {
    [_pressingRecords removeObjectForKey:@(physicalKey)];
  } else {
    _pressingRecords[@(physicalKey)] = @(logicalKey);
  }
}

- (void)sendPrimaryFlutterEvent:(const FlutterKeyEvent&)event
                       callback:(FlutterKeyCallbackGuard*)callback {
  _responseId += 1;
  uint64_t responseId = _responseId;
  FlutterKeyPendingResponse* pending =
      [[FlutterKeyPendingResponse alloc] initWithHandler:self responseId:responseId];
  [callback pendTo:_pendingResponses withId:responseId];
  // The `__bridge_retained` here is matched by `__bridge_transfer` in HandleResponse.
  _sendEvent(event, HandleResponse, (__bridge_retained void*)pending);
}

- (void)sendCapsLockTapWithTimestamp:(NSTimeInterval)timestamp
                            callback:(FlutterKeyCallbackGuard*)downCallback {
  // MacOS sends a down *or* an up when CapsLock is tapped, alternatively on
  // even taps and odd taps. A CapsLock down or CapsLock up should always be
  // converted to a down *and* an up, and the up should always be a synthesized
  // event, since we will never know when the button is released.
  FlutterKeyEvent flutterEvent = {
      .struct_size = sizeof(FlutterKeyEvent),
      .timestamp = GetFlutterTimestampFrom(timestamp),
      .type = kFlutterKeyEventTypeDown,
      .physical = kCapsLockPhysicalKey,
      .logical = kCapsLockLogicalKey,
      .character = nil,
      .synthesized = downCallback == nil,
  };
  if (downCallback != nil) {
    [self sendPrimaryFlutterEvent:flutterEvent callback:downCallback];
  } else {
    _sendEvent(flutterEvent, nullptr, nullptr);
  }

  flutterEvent.type = kFlutterKeyEventTypeUp;
  flutterEvent.synthesized = true;
  _sendEvent(flutterEvent, nullptr, nullptr);
}

- (void)sendModifierEventOfType:(BOOL)isDownEvent
                      timestamp:(NSTimeInterval)timestamp
                        keyCode:(unsigned short)keyCode
                       callback:(FlutterKeyCallbackGuard*)callback {
  uint64_t physicalKey = GetPhysicalKeyForKeyCode(keyCode);
  uint64_t logicalKey = GetLogicalKeyForModifier(keyCode, physicalKey);
  if (physicalKey == 0 || logicalKey == 0) {
    NSLog(@"Unrecognized modifier key: keyCode 0x%hx, physical key 0x%llx", keyCode, physicalKey);
    [callback resolveTo:TRUE];
    return;
  }
  FlutterKeyEvent flutterEvent = {
      .struct_size = sizeof(FlutterKeyEvent),
      .timestamp = GetFlutterTimestampFrom(timestamp),
      .type = isDownEvent ? kFlutterKeyEventTypeDown : kFlutterKeyEventTypeUp,
      .physical = physicalKey,
      .logical = logicalKey,
      .character = nil,
      .synthesized = callback == nil,
  };
  [self updateKey:physicalKey asPressed:isDownEvent ? logicalKey : 0];
  if (callback != nil) {
    [self sendPrimaryFlutterEvent:flutterEvent callback:callback];
  } else {
    _sendEvent(flutterEvent, nullptr, nullptr);
  }
}

- (void)handleDownEvent:(NSEvent*)event callback:(FlutterKeyCallbackGuard*)callback {
  uint64_t physicalKey = GetPhysicalKeyForKeyCode(event.keyCode);
  uint64_t logicalKey = GetLogicalKeyForEvent(event, physicalKey);
  [self synchronizeModifiers:event.modifierFlags ignoringFlags:0 timestamp:event.timestamp];

  bool isARepeat = event.isARepeat;
  NSNumber* pressedLogicalKey = _pressingRecords[@(physicalKey)];
  if (pressedLogicalKey != nil && !isARepeat) {
    // Normally the key up events won't be missed since macOS always sends the
    // key up event to the window where the corresponding key down occurred.
    // However this might happen in add-to-app scenarios if the focus is changed
    // from the native view to the Flutter view amid the key tap.
    [callback resolveTo:TRUE];
    return;
  }
  bool isSynthesized = false;

  if (pressedLogicalKey == nil) {
    [self updateKey:physicalKey asPressed:logicalKey];
  }

  FlutterKeyEvent flutterEvent = {
      .struct_size = sizeof(FlutterKeyEvent),
      .timestamp = GetFlutterTimestampFrom(event.timestamp),
      .type = isARepeat ? kFlutterKeyEventTypeRepeat : kFlutterKeyEventTypeDown,
      .physical = physicalKey,
      .logical = pressedLogicalKey == nil ? logicalKey : [pressedLogicalKey unsignedLongLongValue],
      .character = getEventString(event.characters),
      .synthesized = isSynthesized,
  };
  [self sendPrimaryFlutterEvent:flutterEvent callback:callback];
}

- (void)handleUpEvent:(NSEvent*)event callback:(FlutterKeyCallbackGuard*)callback {
  NSAssert(!event.isARepeat, @"Unexpected repeated Up event: keyCode %d, char %@, charIM %@",
           event.keyCode, event.characters, event.charactersIgnoringModifiers);
  [self synchronizeModifiers:event.modifierFlags ignoringFlags:0 timestamp:event.timestamp];

  uint64_t physicalKey = GetPhysicalKeyForKeyCode(event.keyCode);
  NSNumber* pressedLogicalKey = _pressingRecords[@(physicalKey)];
  if (pressedLogicalKey == nil) {
    // Normally the key up events won't be missed since macOS always sends the
    // key up event to the window where the corresponding key down occurred.
    // However this might happen in add-to-app scenarios if the focus is changed
    // from the native view to the Flutter view amid the key tap.
    [callback resolveTo:TRUE];
    return;
  }
  [self updateKey:physicalKey asPressed:0];

  FlutterKeyEvent flutterEvent = {
      .struct_size = sizeof(FlutterKeyEvent),
      .timestamp = GetFlutterTimestampFrom(event.timestamp),
      .type = kFlutterKeyEventTypeUp,
      .physical = physicalKey,
      .logical = [pressedLogicalKey unsignedLongLongValue],
      .character = nil,
      .synthesized = false,
  };
  [self sendPrimaryFlutterEvent:flutterEvent callback:callback];
}

- (void)handleCapsLockEvent:(NSEvent*)event callback:(FlutterKeyCallbackGuard*)callback {
  [self synchronizeModifiers:event.modifierFlags
               ignoringFlags:NSEventModifierFlagCapsLock
                   timestamp:event.timestamp];
  if ((_lastModifierFlagsOfInterest & NSEventModifierFlagCapsLock) !=
      (event.modifierFlags & NSEventModifierFlagCapsLock)) {
    [self sendCapsLockTapWithTimestamp:event.timestamp callback:callback];
    _lastModifierFlagsOfInterest = _lastModifierFlagsOfInterest ^ NSEventModifierFlagCapsLock;
  } else {
    [callback resolveTo:TRUE];
  }
}

- (void)handleFlagEvent:(NSEvent*)event callback:(FlutterKeyCallbackGuard*)callback {
  NSNumber* targetModifierFlagObj = keyCodeToModifierFlag[@(event.keyCode)];
  NSUInteger targetModifierFlag =
      targetModifierFlagObj == nil ? 0 : [targetModifierFlagObj unsignedLongValue];
  uint64_t targetKey = GetPhysicalKeyForKeyCode(event.keyCode);
  if (targetKey == kCapsLockPhysicalKey) {
    return [self handleCapsLockEvent:event callback:callback];
  }

  [self synchronizeModifiers:event.modifierFlags
               ignoringFlags:targetModifierFlag
                   timestamp:event.timestamp];

  NSNumber* pressedLogicalKey = [_pressingRecords objectForKey:@(targetKey)];
  BOOL lastTargetPressed = pressedLogicalKey != nil;
  NSAssert(targetModifierFlagObj == nil ||
               (_lastModifierFlagsOfInterest & targetModifierFlag) != 0 == lastTargetPressed,
           @"Desynchronized state between lastModifierFlagsOfInterest (0x%lx) on bit 0x%lx "
           @"for keyCode 0x%hx, whose pressing state is %@.",
           _lastModifierFlagsOfInterest, targetModifierFlag, event.keyCode,
           lastTargetPressed
               ? [NSString stringWithFormat:@"0x%llx", [pressedLogicalKey unsignedLongLongValue]]
               : @"empty");

  BOOL shouldBePressed = (event.modifierFlags & targetModifierFlag) != 0;
  if (lastTargetPressed == shouldBePressed) {
    [callback resolveTo:TRUE];
    return;
  }
  _lastModifierFlagsOfInterest = _lastModifierFlagsOfInterest ^ targetModifierFlag;
  [self sendModifierEventOfType:shouldBePressed
                      timestamp:event.timestamp
                        keyCode:event.keyCode
                       callback:callback];
}

- (void)handleResponse:(BOOL)handled forId:(uint64_t)responseId {
  FlutterAsyncKeyCallback callback = _pendingResponses[@(responseId)];
  callback(handled);
  [_pendingResponses removeObjectForKey:@(responseId)];
}

@end

namespace {
void HandleResponse(bool handled, void* user_data) {
  // The `__bridge_transfer` here is matched by `__bridge_retained` in sendPrimaryFlutterEvent.
  FlutterKeyPendingResponse* pending = (__bridge_transfer FlutterKeyPendingResponse*)user_data;
  [pending.responder handleResponse:handled forId:pending.responseId];
}
}  // namespace
