//
//  SocketConnection.h
//  ZetaConsole
//
//  Created by Søren Bruus Frank on 18/04/14.
//  Copyright (c) 2014 Bruus Frank. All rights reserved.
//

#import <Foundation/Foundation.h>

@class SocketConnection;

@protocol SocketConnectionDelegate

- (void) connectionAttemptFailed:(SocketConnection*)connection;
- (void) connectionTerminated:(SocketConnection*)connection;
- (void) receivedNetworkPacket:(NSDictionary*)message viaConnection:(SocketConnection*)connection;

@end

@interface SocketConnection : NSObject <NSNetServiceDelegate, NSStreamDelegate>

//Connection info: host address and port.
@property (nonatomic, strong) NSString *host;
@property (nonatomic, assign) int port;

//Connection info: native socket handle.
@property (nonatomic, assign) CFSocketNativeHandle connectedSocketHandle;

//Connection info: NSNetService.
@property (nonatomic, strong) NSNetService *netService;

//Streams.
@property (nonatomic, strong) NSInputStream *inputStream;
@property (nonatomic, assign) BOOL inputStreamOpen;
@property (nonatomic, strong) NSMutableData *incomingDataBuffer;

@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, assign) BOOL outputStreamOpen;
@property (nonatomic, strong) NSMutableData *outgoingDataBuffer;

@property (nonatomic, retain) id<SocketConnectionDelegate> delegate;

// Initialize and store connection information until 'connect' is called
- (id)initWithHostAddress:(NSString*)host andPort:(int)port;

// Initialize using a native socket handle, assuming connection is open
- (id)initWithNativeSocketHandle:(CFSocketNativeHandle)nativeSocketHandle;

// Initialize using an instance of NSNetService
- (id)initWithNetService:(NSNetService*)netService;

// Connect using whatever connection info that was passed during initialization
- (BOOL)connect;

// Close connection
- (void)close;

// Send network message
- (void)sendNetworkPacket:(NSDictionary*)packet;

@end
