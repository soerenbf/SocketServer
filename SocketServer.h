//
//  SocketServer.h
//
//  Created by Søren Bruus Frank on 13/04/14.
//  Copyright (c) 2014 Bruus Frank. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "SocketConnection.h"

@class SocketServer;

@protocol SocketServerDelegate

// Server has been terminated because of an error
- (void) serverFailed:(SocketServer *)server reason:(NSString*)reason;

// Server has accepted a new connection and it needs to be processed
- (void) handleNewConnection:(SocketConnection*)connection;

@end

typedef enum {
    CFSocket = 0,
    POSIXSocket = 1
} socketType;

@interface SocketServer : NSObject <NSNetServiceDelegate>

@property (nonatomic, strong) NSNetService *service;
@property (nonatomic, assign) CFSocketRef cfSocket;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, strong) id<SocketServerDelegate> delegate;

- (SocketServer *)init;
- (SocketServer *)initWithSocketType:(socketType)socketType;

- (BOOL)start;
- (void)terminate;

- (BOOL)publishService;
- (void)unpublishService;

@end
