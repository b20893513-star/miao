#import "MPAppDelegate.h"
#import "MPRootViewController.h"

@implementation MPAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	UINavigationController *nav = [[UINavigationController alloc]
		initWithRootViewController:[MPRootViewController new]];
	nav.navigationBar.prefersLargeTitles = YES;
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];
	return YES;
}

@end
