/**
 * @copyright Copyright (c) 2020 Ivan Sein <ivan@nextcloud.com>
 *
 * @author Ivan Sein <ivan@nextcloud.com>
 *
 * @license GNU GPL version 3 or any later version
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#import "NCExternalSignalingController.h"

#import "NCAPIController.h"
#import "NCDatabaseManager.h"
#import "NCRoomsManager.h"
#import "NCSettingsController.h"
#import "WSMessage.h"

#import "NextcloudTalk-Swift.h"

static NSTimeInterval kInitialReconnectInterval = 1;
static NSTimeInterval kMaxReconnectInterval     = 16;
static NSTimeInterval kWebSocketTimeoutInterval = 15;

@interface NCExternalSignalingController () <NSURLSessionWebSocketDelegate>

@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocket;
@property (nonatomic, strong) NSString* serverUrl;
@property (nonatomic, strong) NSString* ticket;
@property (nonatomic, strong) NSString* resumeId;
@property (nonatomic, strong) NSString* sessionId;
@property (nonatomic, strong) NSString* userId;
@property (nonatomic, strong) NSString* authenticationBackendUrl;
@property (nonatomic, assign) BOOL helloResponseReceived;
@property (nonatomic, assign) BOOL mcuSupport;
@property (nonatomic, strong) NSMutableDictionary* participantsMap;
@property (nonatomic, strong) NSMutableArray* pendingMessages;
@property (nonatomic, assign) NSInteger messageId;
@property (nonatomic, strong) WSMessage *helloMessage;
@property (nonatomic, strong) NSMutableArray *messagesWithCompletionBlocks;
@property (nonatomic, assign) NSInteger reconnectInterval;
@property (nonatomic, strong) NSTimer *reconnectTimer;
@property (nonatomic, assign) BOOL sessionChanged;

@end

@implementation NCExternalSignalingController

+ (NCExternalSignalingController *)sharedInstance
{
    static dispatch_once_t once;
    static NCExternalSignalingController *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)initWithAccount:(TalkAccount *)account server:(NSString *)serverUrl andTicket:(NSString *)ticket
{
    self = [super init];
    if (self) {
        _account = account;
        _userId = _account.userId;
        _authenticationBackendUrl = [[NCAPIController sharedInstance] authenticationBackendUrlForAccount:_account];
        [self setServer:serverUrl andTicket:ticket];
    }
    return self;
}

- (BOOL)isEnabled
{
    return (_serverUrl) ? YES : NO;
}

- (BOOL)hasMCU
{
    return _mcuSupport;
}

- (NSString *)sessionId
{
    return _sessionId;
}

- (void)setServer:(NSString *)serverUrl andTicket:(NSString *)ticket
{
    _serverUrl = [self getWebSocketUrlForServer:serverUrl];
    _ticket = ticket;
    _reconnectInterval = kInitialReconnectInterval;
    _pendingMessages = [NSMutableArray new];
    
    [self connect];
}

- (NSString *)getWebSocketUrlForServer:(NSString *)serverUrl
{
    NSString *wsUrl = [serverUrl copy];
    
    // Change to websocket protocol
    wsUrl = [wsUrl stringByReplacingOccurrencesOfString:@"https://" withString:@"wss://"];
    wsUrl = [wsUrl stringByReplacingOccurrencesOfString:@"http://" withString:@"ws://"];
    // Remove trailing slash
    if([wsUrl hasSuffix:@"/"]) {
        wsUrl = [wsUrl substringToIndex:[wsUrl length] - 1];
    }
    // Add spreed endpoint
    wsUrl = [wsUrl stringByAppendingString:@"/spreed"];
    
    return wsUrl;
}

#pragma mark - WebSocket connection

- (void)connect
{
    // Do not try to connect if the app is running in the background
    if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateBackground) {
        [NCUtils log:@"Trying to create websocket connection while app is in the background"];
        return;
    }

    [self invalidateReconnectionTimer];
    _disconnected = NO;
    _messageId = 1;
    _messagesWithCompletionBlocks = [NSMutableArray new];
    _helloResponseReceived = NO;
    NSLog(@"Connecting to: %@",  _serverUrl);
    NSURL *url = [NSURL URLWithString:_serverUrl];
    NSURLSession *wsSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
    NSURLRequest *wsRequest = [[NSURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:kWebSocketTimeoutInterval];
    NSURLSessionWebSocketTask *webSocket = [wsSession webSocketTaskWithRequest:wsRequest];

    _webSocket = webSocket;
    
    [_webSocket resume];

    [self receiveMessage];
}

- (void)reconnect
{
    // Note: Make sure to call reconnect only from the main-thread!
    if (_reconnectTimer) {
        return;
    }

    [self resetWebSocket];

    [self executeAllCompletionBlocksWithError];

    [self setReconnectionTimer];
}

- (void)forceReconnect
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_resumeId = nil;
        [self reconnect];
    });
}

- (void)disconnect
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self invalidateReconnectionTimer];
        [self resetWebSocket];
    });
}

- (void)resetWebSocket
{
    [_webSocket cancel];
    _webSocket = nil;
    _helloResponseReceived = NO;
    [_helloMessage ignoreCompletionBlock];
    _helloMessage = nil;
    _disconnected = YES;
}

- (void)setReconnectionTimer
{
    [self invalidateReconnectionTimer];
    // Wiggle interval a little bit to prevent all clients from connecting
    // simultaneously in case the server connection is interrupted.
    NSInteger interval = _reconnectInterval - (_reconnectInterval / 2) + arc4random_uniform((int)_reconnectInterval);
    NSLog(@"Reconnecting in %ld", (long)interval);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(connect) userInfo:nil repeats:NO];
    });
    _reconnectInterval = _reconnectInterval * 2;
    if (_reconnectInterval > kMaxReconnectInterval) {
        _reconnectInterval = kMaxReconnectInterval;
    }
}

- (void)invalidateReconnectionTimer
{
    [_reconnectTimer invalidate];
    _reconnectTimer = nil;
}

#pragma mark - WebSocket messages

- (void)sendMessage:(NSDictionary *)jsonDict withCompletionBlock:(SendMessageCompletionBlock)block
{
    WSMessage *wsMessage = [[WSMessage alloc] initWithMessage:jsonDict withCompletionBlock:block];

    // Add message as pending message if websocket is not connected
    if (!_helloResponseReceived && !wsMessage.isHelloMessage) {
        [_pendingMessages addObject:wsMessage];
        return;
    }

    [self sendMessage:wsMessage];
}

- (void)sendMessage:(WSMessage *)wsMessage
{
    // Assign messageId and timeout to messages with completionBlocks
    if (wsMessage.completionBlock) {
        NSString *messageIdString = [NSString stringWithFormat: @"%ld", (long)_messageId++];
        wsMessage.messageId = messageIdString;

        if (wsMessage.isHelloMessage) {
            [_helloMessage ignoreCompletionBlock];
            _helloMessage = wsMessage;
        } else {
            [_messagesWithCompletionBlocks addObject:wsMessage];
        }
    }

    if (!wsMessage.webSocketMessage) {
        NSLog(@"Error creating websocket message");
        [wsMessage executeCompletionBlockWithError];
        return;
    }

    [wsMessage sendMessageWithWebSocket:_webSocket];
}

- (void)sendHelloWithCompletionBlock:(SendMessageCompletionBlock)block
{
    NSDictionary *helloDict = @{
                                @"type": @"hello",
                                @"hello": @{
                                        @"version": @"1.0",
                                        @"auth": @{
                                                @"url": _authenticationBackendUrl,
                                                @"params": @{
                                                        @"userid": _userId,
                                                        @"ticket": _ticket
                                                        }
                                                }
                                        }
                                };
    // Try to resume session
    if (_resumeId) {
        helloDict = @{
                      @"type": @"hello",
                      @"hello": @{
                              @"version": @"1.0",
                              @"resumeid": _resumeId
                              }
                      };
    }
    
    [self sendMessage:helloDict withCompletionBlock:block];
}

- (void)helloResponseReceived:(NSDictionary *)messageDict
{
    _helloResponseReceived = YES;

    NSString *messageId = [messageDict objectForKey:@"id"];
    [self executeCompletionBlockForMessageId:messageId withError:NO];

    NSDictionary *helloDict = [messageDict objectForKey:@"hello"];
    _resumeId = [helloDict objectForKey:@"resumeid"];
    NSString *newSessionId = [helloDict objectForKey:@"sessionid"];
    _sessionChanged = _sessionId && ![_sessionId isEqualToString:newSessionId];
    _sessionId = newSessionId;
    NSArray *serverFeatures = [[helloDict objectForKey:@"server"] objectForKey:@"features"];
    for (NSString *feature in serverFeatures) {
        if ([feature isEqualToString:@"mcu"]) {
            _mcuSupport = YES;
        }
    }

    NSString *serverVersion = [[helloDict objectForKey:@"server"] objectForKey:@"version"];
    dispatch_async(dispatch_get_main_queue(), ^{
        BGTaskHelper *bgTask = [BGTaskHelper startBackgroundTaskWithName:@"NCUpdateSignalingVersionTransaction" expirationHandler:nil];
        [[NCDatabaseManager sharedInstance] setExternalSignalingServerVersion:serverVersion forAccountId:self->_account.accountId];
        [bgTask stopBackgroundTask];
    });
    
    // Send pending messages
    for (WSMessage *wsMessage in _pendingMessages) {
        [self sendMessage:wsMessage];
    }
    _pendingMessages = [NSMutableArray new];
    
    // Re-join if user was in a room
    if (_currentRoom && _sessionChanged) {
        [self.delegate externalSignalingControllerWillRejoinCall:self];
        [[NCRoomsManager sharedInstance] rejoinRoom:_currentRoom];
    }
}

- (void)errorResponseReceived:(NSDictionary *)messageDict
{
    NSString *errorCode = [[messageDict objectForKey:@"error"] objectForKey:@"code"];
    if ([errorCode isEqualToString:@"no_such_session"]) {
        [self forceReconnect];
        return;
    }

    NSString *messageId = [messageDict objectForKey:@"id"];
    [self executeCompletionBlockForMessageId:messageId withError:YES];
}

- (void)joinRoom:(NSString *)roomId withSessionId:(NSString *)sessionId withCompletionBlock:(JoinRoomExternalSignalingCompletionBlock)block
{
    NSDictionary *messageDict = @{
                                  @"type": @"room",
                                  @"room": @{
                                          @"roomid": roomId,
                                          @"sessionid": sessionId
                                          }
                                  };

    [self sendMessage:messageDict withCompletionBlock:^(NSURLSessionWebSocketTask *task, NSError *error) {
        if (error && task == self->_webSocket) {
            // Reconnect if this is still the same socket we tried to send the message on
            [self reconnect];
        }

        if (block) {
            block(error);
        }
    }];
}

- (void)leaveRoom:(NSString *)roomId
{
    if ([_currentRoom isEqualToString:roomId]) {
        _currentRoom = nil;
        [self joinRoom:@"" withSessionId:@"" withCompletionBlock:nil];
    } else {
        NSLog(@"External signaling: Not leaving because it's not room we joined");
    }
}

- (void)sendCallMessage:(NCSignalingMessage *)message
{
    NSDictionary *messageDict = @{
                                  @"type": @"message",
                                  @"message": @{
                                          @"recipient": @{
                                                  @"type": @"session",
                                                  @"sessionid": message.to
                                                  },
                                          @"data": [message functionDict]
                                          }
                                  };
    
    [self sendMessage:messageDict withCompletionBlock:nil];
}

- (void)requestOfferForSessionId:(NSString *)sessionId andRoomType:(NSString *)roomType
{
    NSDictionary *messageDict = @{
                                  @"type": @"message",
                                  @"message": @{
                                          @"recipient": @{
                                                  @"type": @"session",
                                                  @"sessionid": sessionId
                                                  },
                                          @"data": @{
                                                  @"type": @"requestoffer",
                                                  @"roomType": roomType
                                                  }
                                          }
                                  };
    
    [self sendMessage:messageDict withCompletionBlock:nil];
}

- (void)roomMessageReceived:(NSDictionary *)messageDict
{
    _participantsMap = [NSMutableDictionary new];
    _currentRoom = [[messageDict objectForKey:@"room"] objectForKey:@"roomid"];
    
    NSString *messageId = [messageDict objectForKey:@"id"];
    [self executeCompletionBlockForMessageId:messageId withError:NO];
    
    // Notify that session has change to rejoin the call if currently in a call
    if (_sessionChanged) {
        _sessionChanged = NO;
        [self.delegate externalSignalingControllerShouldRejoinCall:self];
    }
}

- (void)eventMessageReceived:(NSDictionary *)eventDict
{
    NSString *eventTarget = [eventDict objectForKey:@"target"];
    if ([eventTarget isEqualToString:@"room"]) {
        [self processRoomEvent:eventDict];
    } else if ([eventTarget isEqualToString:@"roomlist"]) {
        [self processRoomListEvent:eventDict];
    } else if ([eventTarget isEqualToString:@"participants"]) {
        [self processRoomParticipantsEvent:eventDict];
    } else {
        NSLog(@"Unsupported event target: %@", eventDict);
    }
}

- (void)processRoomEvent:(NSDictionary *)eventDict
{
    NSString *eventType = [eventDict objectForKey:@"type"];
    if ([eventType isEqualToString:@"join"]) {
        NSArray *joins = [eventDict objectForKey:@"join"];
        for (NSDictionary *participant in joins) {
            NSString *participantId = [participant objectForKey:@"userid"];
            if (!participantId || [participantId isEqualToString:@""]) {
                NSLog(@"Guest joined room.");
            } else {
                if ([participantId isEqualToString:_userId]) {
                    NSLog(@"App user joined room.");
                } else {
                    NSLog(@"Participant joined room.");
                }
                [_participantsMap setObject:participant forKey:[participant objectForKey:@"sessionid"]];
            }
        }
    } else if ([eventType isEqualToString:@"leave"]) {
        NSLog(@"Participant left room.");
    } else if ([eventType isEqualToString:@"message"]) {
        [self processRoomMessageEvent:[eventDict objectForKey:@"message"]];
    } else {
        NSLog(@"Unknown room event: %@", eventDict);
    }
}

- (void)processRoomMessageEvent:(NSDictionary *)messageDict
{
    NSString *messageType = [[messageDict objectForKey:@"data"] objectForKey:@"type"];
    if ([messageType isEqualToString:@"chat"]) {
        NSLog(@"Chat message received.");
    } else {
        NSLog(@"Unknown room message type: %@", messageDict);
    }
}

- (void)processRoomListEvent:(NSDictionary *)eventDict
{
    NSLog(@"Refresh room list.");
}

- (void)processRoomParticipantsEvent:(NSDictionary *)eventDict
{
    NSString *eventType = [eventDict objectForKey:@"type"];
    if ([eventType isEqualToString:@"update"]) {
        NSLog(@"Participant list changed: %@", [eventDict objectForKey:@"update"]);
        [self.delegate externalSignalingController:self didReceivedParticipantListMessage:[eventDict objectForKey:@"update"]];
    } else {
        NSLog(@"Unknown room event: %@", eventDict);
    }
}

- (void)messageReceived:(NSDictionary *)messageDict
{
    NSLog(@"Message received");
    [self.delegate externalSignalingController:self didReceivedSignalingMessage:messageDict];
}

#pragma mark - Completion blocks

- (void)executeCompletionBlockForMessageId:(NSString *)messageId withError:(BOOL)withError
{
    if (!messageId) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self->_helloMessage.messageId isEqualToString:messageId]) {
            [self executeCompletionBlockForMessage:self->_helloMessage withError:withError];
            self->_helloMessage = nil;
            return;
        }

        for (WSMessage *message in self->_messagesWithCompletionBlocks) {
            if ([messageId isEqualToString:message.messageId]) {
                [self executeCompletionBlockForMessage:message withError:withError];
                [self->_messagesWithCompletionBlocks removeObject:message];
                break;
            }
        }
    });
}

- (void)executeCompletionBlockForMessage:(WSMessage *)message withError:(BOOL)withError
{
    if (withError) {
        [message executeCompletionBlockWithError];
    } else {
        [message executeCompletionBlockWithSuccess];
    }
}

- (void)executeAllCompletionBlocksWithError
{
    dispatch_async(dispatch_get_main_queue(), ^{
        for (WSMessage *message in self->_messagesWithCompletionBlocks) {
            [message executeCompletionBlockWithError];
        }
    });
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (webSocketTask != self->_webSocket) {
            return;
        }


        NSLog(@"WebSocket Connected!");
        self->_reconnectInterval = kInitialReconnectInterval;
        [self sendHelloWithCompletionBlock:^(NSURLSessionWebSocketTask *task, NSError *error) {
            if (error && task == self->_webSocket) {
                [self reconnect];
            }
        }];
    });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (webSocketTask != self->_webSocket) {
            return;
        }

        NSLog(@"WebSocket didCloseWithCode:%ld reason:%@", (long)closeCode, reason);
        [self reconnect];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (task != self->_webSocket) {
            return;
        }

        if (error) {
            NSLog(@"WebSocket session didCompleteWithError: %@", error.description);
            [self reconnect];
        }
    });
}

- (void)receiveMessage {
    __weak NCExternalSignalingController *weakSelf = self;
    __block NSURLSessionWebSocketTask *receivingWebSocket = _webSocket;

    [_webSocket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        if (!error) {
            NSData *messageData = message.data;
            NSString *messageString = message.string;

            if (message.type == NSURLSessionWebSocketMessageTypeString) {
                messageData = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            }

            if (message.type == NSURLSessionWebSocketMessageTypeData) {
                messageString = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
            }

            NSLog(@"WebSocket didReceiveMessage: %@", messageString);
            NSDictionary *messageDict = [weakSelf getWebSocketMessageFromJSONData:messageData];
            NSString *messageType = [messageDict objectForKey:@"type"];
            if ([messageType isEqualToString:@"hello"]) {
                [weakSelf helloResponseReceived:messageDict];
            } else if ([messageType isEqualToString:@"error"]) {
                [weakSelf errorResponseReceived:messageDict];
            } else if ([messageType isEqualToString:@"room"]) {
                [weakSelf roomMessageReceived:messageDict];
            } else if ([messageType isEqualToString:@"event"]) {
                [weakSelf eventMessageReceived:[messageDict objectForKey:@"event"]];
            } else if ([messageType isEqualToString:@"message"]) {
                [weakSelf messageReceived:[messageDict objectForKey:@"message"]];
            } else if ([messageType isEqualToString:@"control"]) {
                [weakSelf messageReceived:[messageDict objectForKey:@"control"]];
            }
            
            // Completion block for messageId should have been handled already at this point
            NSString *messageId = [messageDict objectForKey:@"id"];
            [weakSelf executeCompletionBlockForMessageId:messageId withError:YES];

            [weakSelf receiveMessage];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Only try to reconnect if the webSocket is still the one we tried to receive a message on
                if (receivingWebSocket != weakSelf.webSocket) {
                    return;
                }

                NSLog(@"WebSocket receiveMessageWithCompletionHandler error %@", error.description);
                [weakSelf reconnect];
            });
        }
    }];
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
    } else {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

#pragma mark - Utils

- (NSString *)getUserIdFromSessionId:(NSString *)sessionId
{
    NSString *userId = nil;
    NSDictionary *user = [_participantsMap objectForKey:sessionId];
    if (user) {
        userId = [user objectForKey:@"userid"];
    }
    return userId;
}

- (NSString *)getDisplayNameFromSessionId:(NSString *)sessionId
{
    NSString *displayName = nil;
    NSDictionary *user = [_participantsMap objectForKey:sessionId];
    if (user) {
        NSDictionary *userSubKey = [user objectForKey:@"user"];
        
        if (userSubKey) {
            displayName = [userSubKey objectForKey:@"displayname"];
        }
    }
    return displayName;
}

- (NSDictionary *)getWebSocketMessageFromJSONData:(NSData *)jsonData
{
    NSError *error;
    NSDictionary* messageDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                                options:kNilOptions
                                                                  error:&error];
    if (!messageDict) {
        NSLog(@"Error parsing websocket message: %@", error);
    }
    
    return messageDict;
}

@end
