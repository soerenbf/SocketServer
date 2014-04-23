//
//  SocketServer.m
//  ZetaConsole
//
//  Created by Søren Bruus Frank on 13/04/14.
//  Copyright (c) 2014 Bruus Frank. All rights reserved.
//

#import "SocketServer.h"
#include <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <netinet/in.h>

@interface SocketServer () {
    dispatch_queue_t serverQueue;
}

@property (nonatomic, assign) socketType socketType;
@property (nonatomic, strong) NSMutableArray *connections;

//Callback for kCFSocketAcceptCallBack.
static void handleConnect(CFSocketRef sock, CFSocketCallBackType type, CFDataRef address, const void *data, void *info);

//Private functions.
- (BOOL)openSocketPOSIX;
- (BOOL)openSocketCF;

- (void)closeSocketPOSIX;
- (void)closeSocketCF;

@end

@implementation SocketServer

#pragma mark - Setters/getters

- (NSMutableArray *)connections
{
    if (!_connections) {
        _connections = [[NSMutableArray alloc] init];
    }
    return _connections;
}

#pragma mark - publically accessible functions

- (SocketServer *)init
{
    return [self initWithSocketType:CFSocket];
}

- (SocketServer *)initWithSocketType:(socketType)socketType
{
    self = [super init];
    _socketType = socketType;
    return self;
}

- (BOOL)start
{
    BOOL success;
    if (self.socketType == POSIXSocket) {
        success =  [self openSocketPOSIX];
    } else {
        success = [self openSocketCF];
    }
    
    [self publishService];
    
    return success;
}

- (void)terminate
{
    self.port = 0;
    self.service = nil;
    self.socketType = -1;
    self.connections = nil;
    
    if (self.socketType == POSIXSocket) {
        [self closeSocketPOSIX];
    } else {
        [self closeSocketCF];
    }
    
    [self unpublishService];
}

#pragma mark - server creation

- (BOOL)openSocketPOSIX
{
    //Create the socket
    int ipv4_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); //IPv4 socket
    //int ipv6_socket = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP); //IPv6 socket
    
    //Bind it to a port
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_len = sizeof(sin);
    sin.sin_family = AF_INET; // or AF_INET6 (address family)
    sin.sin_port = htons(0);
    sin.sin_addr.s_addr= INADDR_ANY;
    
    if (bind(ipv4_socket, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        // Handle the error.
        return NO;
    }
    
    socklen_t len = sizeof(sin);
    if (getsockname(ipv4_socket, (struct sockaddr *)&sin, &len) < 0) {
        // Handle error here
        return NO;
    }
    
    //Get the port number with ntohs(sin.sin_port).
    self.port = ntohs(sin.sin_port);
    
    //Listen on the assigned port.
    if (listen(ipv4_socket, 128) < 0) {
        //Handle error.
        return NO;
    }
    
    //STILL NEED TO ADD THIS TO THE RUN LOOP BEFORE IT WILL WORK.
    
    return YES;
}

- (BOOL)openSocketCF
{
    //Define the context for the socket.
    const CFSocketContext socketCtxt = {0, (__bridge void *)self, NULL, NULL, NULL};
    
    //Create the ipv4 and ipv6 sockets.
    self.cfSocket = CFSocketCreate(
                                   kCFAllocatorDefault,
                                   PF_INET,
                                   SOCK_STREAM,
                                   IPPROTO_TCP,
                                   kCFSocketAcceptCallBack,
                                   (CFSocketCallBack)handleConnect,
                                   &socketCtxt);
    
    //Assert that the socket is created.
    if (self.cfSocket == NULL) {
        return NO;
    }
    
    //Bind the socket to an address and port.
    struct sockaddr_in sin;
    
    memset(&sin, 0, sizeof(sin));
    sin.sin_len = sizeof(sin);
    sin.sin_family = AF_INET; /* Address family */
    sin.sin_port = htons(0); /* Or a specific port */
    sin.sin_addr.s_addr= INADDR_ANY;
    
    CFDataRef sincfd = CFDataCreate(
                                    kCFAllocatorDefault,
                                    (UInt8 *)&sin,
                                    sizeof(sin));
    
    if (kCFSocketSuccess != CFSocketSetAddress(self.cfSocket, sincfd)) {
        NSLog(@"CFSocketSetAddress failed");
    }
    CFRelease(sincfd);
    
    //Get the port of the socket.
    NSData *socketAddressActualData = (__bridge NSData *)CFSocketCopyAddress(self.cfSocket);
    //Convert socket data into a usable structure
    struct sockaddr_in socketAddressActual;
    memcpy(&socketAddressActual, [socketAddressActualData bytes],
           [socketAddressActualData length]);
    
    self.port = ntohs(socketAddressActual.sin_port);
    
    //Add the socket to a run loop.
    CFRunLoopSourceRef socketsource = CFSocketCreateRunLoopSource(
                                                                  kCFAllocatorDefault,
                                                                  self.cfSocket,
                                                                  0);
    
    CFRunLoopAddSource(
                       CFRunLoopGetCurrent(),
                       socketsource,
                       kCFRunLoopDefaultMode);
    
    return YES;
}

- (BOOL)publishService
{
    self.service = [[NSNetService alloc] initWithDomain:@"local." type:@"_zeta._tcp." name:@"" port:self.port];
    if (self.service == nil) {
        return NO;
    }
    
    self.service.delegate = self;
    [self.service publish];
    
    return YES;
}

#pragma mark - server termination

- (void)closeSocketPOSIX
{
    //Set POSIX socket reference to NULL.
}

- (void)closeSocketCF
{
    self.cfSocket = NULL;
}

- (void)unpublishService
{
    if (self.service) {
        [self.service stop];
        self.service = nil;
    }
}

#pragma mark - callbacks

static void handleConnect(CFSocketRef sock, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{    
    SocketServer *server = (__bridge SocketServer *)info;
    
    // We can only process "connection accepted" calls here
    if ( type != kCFSocketAcceptCallBack ) {
        return;
    }
    
    // for an AcceptCallBack, the data parameter is a pointer to a CFSocketNativeHandle
    CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;
    
    [server handleNewNativeSocket:nativeSocketHandle];
}

// Handle new connections
- (void)handleNewNativeSocket:(CFSocketNativeHandle)nativeSocketHandle {
    SocketConnection* connection = [[SocketConnection alloc] initWithNativeSocketHandle:nativeSocketHandle];
    
    // In case of errors, close native socket handle
    if ( connection == nil ) {
        close(nativeSocketHandle);
        return;
    }
    
    // finish connecting
    if ( ! [connection connect] ) {
        [connection close];
        return;
    }
    
    [self.connections addObject:connection];
    
    // Pass this on to our delegate
    [self.delegate handleNewConnection:connection];
}

#pragma mark - NSNetServiceDelegate

- (void)netService:(NSNetService*)sender didNotPublish:(NSDictionary*)errorDict {
    if (sender != self.service) {
        return;
    }
    
    // Stop socket server
    [self terminate];
    [self unpublishService];
}

@end
