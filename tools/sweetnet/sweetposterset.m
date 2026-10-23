/*
 * Exit status: 0 selected, 1 create failed (e.g. -2203 while PosterBoard's data store has an empty lock role: retry),
 * 3 select failed.
 *
 * sweetposterset PROVIDER DESCRIPTOR_ID : create a poster configuration from a stock descriptor and select it
 * for the lock screen (the home screen follows its poster). Run via SweetRun (mobile launchd domain).
 *   e.g. sweetposterset com.apple.GradientPoster.GradientPosterExtension darkBlue.preset1
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include "sweetposter-prs.h"
@interface PRSService (SweetX)
- (void)fetchActivePosterForRole:(id)r completion:(void(^)(id,id))c;
@end
@interface NSObject (SweetU) - (id)serverUUID; @end
static void wt(dispatch_semaphore_t s){ for(int i=0;i<300;i++){ if(!dispatch_semaphore_wait(s,DISPATCH_TIME_NOW))return; [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; } printf("TIMEOUT\n"); }
int main(int argc,char**argv){@autoreleasepool{ setvbuf(stdout,0,_IOLBF,0);
 dlopen("/System/Library/PrivateFrameworks/PosterBoardServices.framework/PosterBoardServices",RTLD_NOW);
 PRSService *svc=[[NSClassFromString(@"PRSService") alloc] init];
 dispatch_semaphore_t s=dispatch_semaphore_create(0);
 NSString*role=@"PRPosterRoleLockScreen";
 __block id cfg=nil, serr=nil;
 [svc createPosterConfigurationForProviderIdentifier:[NSString stringWithUTF8String:argv[1]] posterDescriptorIdentifier:[NSString stringWithUTF8String:argv[2]] role:role completion:^(id a,id b){printf("create a=%s b=%s\n",[[a description] UTF8String],[[b description] UTF8String]);cfg=a;dispatch_semaphore_signal(s);}]; wt(s);
 if(!cfg) return 1;
 id uuid=[cfg serverUUID]; printf("uuid=%s\n",[[uuid description] UTF8String]);
 [svc updateToSelectedConfigurationMatchingUUID:uuid role:role completion:^(id a,id b){printf("select a=%s b=%s\n",[[a description] UTF8String],[[b description] UTF8String]);serr=b;dispatch_semaphore_signal(s);}]; wt(s);
 if(serr) return 3;
 [svc fetchSelectedPosterForRole:role completion:^(id a,id b){printf("selected a=%s b=%s\n",[[a description] UTF8String],[[b description] UTF8String]);dispatch_semaphore_signal(s);}]; wt(s);
}return 0;}
