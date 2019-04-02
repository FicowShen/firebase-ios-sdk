/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "GDTTransformer.h"
#import "GDTTransformer_Private.h"

#import <GoogleDataTransport/GDTEventTransformer.h>

#import "GDTAssert.h"
#import "GDTConsoleLogger.h"
#import "GDTStorage.h"

@implementation GDTTransformer

+ (instancetype)sharedInstance {
  static GDTTransformer *eventTransformer;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    eventTransformer = [[self alloc] init];
  });
  return eventTransformer;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _eventWritingQueue = dispatch_queue_create("com.google.GDTTransformer", DISPATCH_QUEUE_SERIAL);
    _storageInstance = [GDTStorage sharedInstance];
  }
  return self;
}

- (void)transformEvent:(GDTEvent *)event
      withTransformers:(NSArray<id<GDTEventTransformer>> *)transformers {
  GDTAssert(event, @"You can't write a nil event");
  dispatch_async(_eventWritingQueue, ^{
    GDTEvent *transformedEvent = event;
    for (id<GDTEventTransformer> transformer in transformers) {
      if ([transformer respondsToSelector:@selector(transform:)]) {
        transformedEvent = [transformer transform:transformedEvent];
        if (!transformedEvent) {
          return;
        }
      } else {
        GDTLogError(GDTMCETransformerDoesntImplementTransform,
                    @"Transformer doesn't implement transform: %@", transformer);
        return;
      }
    }
    [self.storageInstance storeEvent:transformedEvent];
  });
}

@end