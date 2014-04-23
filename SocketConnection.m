//
//  SocketConnection.m
//  ZetaConsole
//
//  Created by Søren Bruus Frank on 18/04/14.
//  Copyright (c) 2014 Bruus Frank. All rights reserved.
//

#import "SocketConnection.h"

@interface SocketConnection () {
    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    int packetBodySize;
}

// Initialize
- (void)clean;

// Further setup streams created by one of the 'init' methods
- (BOOL)setupSocketStreams;

//Receive data
- (void)receiveDataFromStream:(NSInputStream *)inputStream;

//Write data
- (void)writeDataToStream:(NSOutputStream *)outputStream;

@end

@implementation SocketConnection

#pragma mark - Init

// Initialize, empty
- (void)clean {
    self.inputStream = nil;
    self.inputStreamOpen = NO;
    
    self.outputStream = nil;
    self.outputStreamOpen = NO;
    
    self.incomingDataBuffer = nil;
    self.outgoingDataBuffer = nil;
    
    self.netService = nil;
    self.host = nil;
    self.connectedSocketHandle = -1;
    packetBodySize = -1;
}

// Initialize and store connection information until 'connect' is called
- (id)initWithHostAddress:(NSString*)host andPort:(int)port {
    [self clean];
    
    self.host = host;
    self.port = port;
    return self;
}

// Initialize using a native socket handle, assuming connection is open
- (id)initWithNativeSocketHandle:(CFSocketNativeHandle)nativeSocketHandle {
    [self clean];
    
    self.connectedSocketHandle = nativeSocketHandle;
    return self;
}


// Initialize using an instance of NSNetService
- (id)initWithNetService:(NSNetService*)netService {
    [self clean];
    
    // Has it been resolved?
    if (self.netService.hostName != nil) {
        return [self initWithHostAddress:self.netService.hostName andPort:(int)self.netService.port];
    }
    
    self.netService = netService;
    return self;
}

#pragma mark - Connection creation

// Connect using whatever connection info that was passed during initialization
- (BOOL)connect {
    if (self.host != nil) {
        //Bind read/write streams to a new socket
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)self.host,
                                           self.port, &readStream, &writeStream);
        
        self.inputStream = (__bridge NSInputStream *)readStream;
        self.outputStream = (__bridge NSOutputStream *)writeStream;
        
        // Do the rest
        return [self setupSocketStreams];
    }
    else if (self.connectedSocketHandle != -1) {
        // Bind read/write streams to a socket represented by a native socket handle
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, self.connectedSocketHandle,
                                     &readStream, &writeStream);
        
        self.inputStream = (__bridge NSInputStream *)readStream;
        self.outputStream = (__bridge NSOutputStream *)writeStream;
        
        // Do the rest
        return [self setupSocketStreams];
    }
    else if (self.netService != nil) {
        // Still need to resolve?
        if (self.netService.hostName != nil) {
            CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)self.netService.hostName, (int)self.netService.port, &readStream, &writeStream);
            
            self.inputStream = (__bridge NSInputStream *)readStream;
            self.outputStream = (__bridge NSOutputStream *)writeStream;
            
            return [self setupSocketStreams];
        }
        
        // Start resolving
        self.netService.delegate = self;
        [self.netService resolveWithTimeout:5.0];
        return YES;
    }
    
    // Nothing was passed, connection is not possible
    return NO;
}

- (BOOL)setupSocketStreams
{
    if (self.inputStream == nil || self.outputStream == nil) {
        return NO;
    }
    
    // Create buffers
    self.incomingDataBuffer = [[NSMutableData alloc] init];
    self.outgoingDataBuffer = [[NSMutableData alloc] init];
    
    self.inputStream.delegate = self;
    self.outputStream.delegate = self;
    
    [self.inputStream open];
    [self.outputStream open];
    return YES;
}

#pragma mark - Close

- (void)close
{
    self.inputStream.delegate = nil;
    self.outputStream.delegate = nil;
    
    [self.inputStream close];
    [self.outputStream close];
    
    self.inputStream = nil;
    self.outputStream = nil;
}

#pragma mark - Send

- (void)sendNetworkPacket:(NSDictionary *)packet
{
    //Queue up the data to be sent.
    NSData *rawPacket = [NSKeyedArchiver archivedDataWithRootObject:packet];
    
    //First write a header, defining the length of the raw packet.
    int packetLength = (int)rawPacket.length;
    [self.outgoingDataBuffer appendBytes:&packetLength length:sizeof(int)];
    [self.outgoingDataBuffer appendData:rawPacket];
    
    //Send the data.
    [self writeDataToStream:self.outputStream];
}

- (void)writeDataToStream:(NSOutputStream *)outputStream
{
    //Check if everything is initialized properly
    if (!self.inputStreamOpen || !self.outputStreamOpen) {
        return;
    }
    //Else, do we have anything to write?
    if (self.outgoingDataBuffer.length == 0){
        return;
    }
    //Can the stream take any data in?
    if (!outputStream.hasSpaceAvailable) {
        return;
    }
    
    //Write as much data as possible.
    NSInteger writtenBytes = [outputStream write:self.outgoingDataBuffer.bytes maxLength:self.outgoingDataBuffer.length];
    
    if ( writtenBytes == -1 ) {
        // Error occurred. Close everything up.
        [self close];
        [self.delegate connectionTerminated:self];
        return;
    }
    
    NSRange range = {0, writtenBytes};
    [self.outgoingDataBuffer replaceBytesInRange:range withBytes:NULL length:0];
    
}

#pragma mark - Receive

- (void)receiveDataFromStream:(NSInputStream *)inputStream
{
    //Check if everything is initialized properly
    if (!self.inputStreamOpen || !self.outputStreamOpen) {
        return;
    }
    //Else, do we have anything to write?
    else if (self.outgoingDataBuffer.length == 0){
        return;
    }
    //Fetch the data from the stream.
    uint8_t buf[1024];
    
    while (inputStream.hasBytesAvailable) {
        NSInteger bytesRead = [inputStream read:buf maxLength:sizeof(buf)];
        if (bytesRead <= 0) {
            // Either stream was closed or error occurred. Close everything up and treat this as "connection terminated"
            [self close];
            [self.delegate connectionTerminated:self];
            return;
        }
        [self.incomingDataBuffer appendBytes:buf length:bytesRead];
    }
    
    //Try to extract packets from the buffer.
    //
    //Protocol: header + body
    //  Header: an integer that indicates length of the body
    //  Body: bytes that represent encoded NSDictionary
    
    //We might have more than one message in the buffer - that's why we'll be reading it inside the while loop
    while(YES) {
        //Did we read the header yet?
        if (packetBodySize == -1) {
            //Do we have enough bytes in the buffer to read the header?
            if ([self.incomingDataBuffer length] >= sizeof(int)) {
                //Extract length, we know this to be the first integer (4 bytes = sizeof(int))of the data packet.
                memcpy(&packetBodySize, [self.incomingDataBuffer bytes], sizeof(int));
                
                //Remove that chunk from buffer
                NSRange rangeToDelete = {0, sizeof(int)};
                [self.incomingDataBuffer replaceBytesInRange:rangeToDelete withBytes:NULL length:0];
            } else {
                //We don't have enough yet. Will wait for more data.
                break;
            }
        }
        
        //We should now have the header. Time to extract the body.
        if ([self.incomingDataBuffer length] >= packetBodySize) {
            //We now have enough data to extract a meaningful packet.
            NSData* raw = [NSData dataWithBytes:[self.incomingDataBuffer bytes] length:packetBodySize];
            NSDictionary* packet = [NSKeyedUnarchiver unarchiveObjectWithData:raw];

            // Tell our delegate about it
            [self.delegate receivedNetworkPacket:packet viaConnection:self];
            
            // Remove that chunk from buffer
            NSRange rangeToDelete = {0, packetBodySize};
            [self.incomingDataBuffer replaceBytesInRange:rangeToDelete withBytes:NULL length:0];
            
            // We have processed the packet. Resetting the state.
            packetBodySize = -1;
        }
        else {
            // Not enough data yet. Will wait.
            break;
        }
    }
}

#pragma mark - NSNetServiceDelegate

// Called if we weren't able to resolve net service
- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary *)errorDict {
    if ( sender != self.netService ) {
        return;
    }
    
    // Close everything and tell delegate that we have failed
    [self.delegate connectionAttemptFailed:self];
    [self close];
}


// Called when net service has been successfully resolved
- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    if ( sender != self.netService ) {
        return;
    }
    
    // Save connection info
    self.host = self.netService.hostName;
    self.port = (int)self.netService.port;
    
    // Don't need the service anymore
    self.netService = nil;
    
    // Connect!
    if ( ![self connect] ) {
        [self.delegate connectionAttemptFailed:self];
        [self close];
    }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
    switch (eventCode) {
        case NSStreamEventHasSpaceAvailable:
        {
            //OutputStream, send data.
            [self writeDataToStream:(NSOutputStream *)aStream];
            break;
        }
        case NSStreamEventHasBytesAvailable:
        {
            //InputStream, receive the data.
            [self receiveDataFromStream:(NSInputStream *)aStream];
            break;
        }
        case NSStreamEventOpenCompleted:
        {
            if (aStream.class == self.inputStream.class) {
                self.inputStreamOpen = YES;
            } else {
                self.outputStreamOpen = YES;
            }
            break;
        }
        case NSStreamEventEndEncountered:
        {
            // Clean everything up
            [self close];
            
            // If we haven't connected yet then our connection attempt has failed
            if ( !self.inputStreamOpen || !self.outputStreamOpen ) {
                [self.delegate connectionAttemptFailed:self];
            }
            else {
                [self.delegate connectionTerminated:self];
            }
            break;
        }
        case NSStreamEventErrorOccurred:
        {
            // Clean everything up
            [self close];
            
            // If we haven't connected yet then our connection attempt has failed
            if ( !self.inputStreamOpen || !self.outputStreamOpen ) {
                [self.delegate connectionAttemptFailed:self];
            }
            else {
                [self.delegate connectionTerminated:self];
            }
            break;
        }
        default:
            break;
    }
}

@end
