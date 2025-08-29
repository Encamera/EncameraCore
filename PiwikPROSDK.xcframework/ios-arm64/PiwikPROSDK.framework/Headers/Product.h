//
//  Product.h
//  PiwikPROSDK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 An ecommerce product.
 @see EcommerceProducts
 */
@interface Product : NSObject

/**
 Unique identifier for the product. Mandatory.
 */
@property (nonatomic, readonly) NSString *sku;

/**
 Product name (default: “”). Optional.
 */
@property (nullable, nonatomic, readonly) NSString *name;

/**
 Product category or an array of up to 5 categories (default: “”). Optional.
 */
@property (nullable, nonatomic, strong) NSArray<NSString *> *category;

/**
 Price of the product (default: 0). Optional.
 */
@property (nullable, nonatomic, readonly) NSString *price;

/**
 Product quantity (default: 1). Optional.
 */
@property (nullable, nonatomic, readonly) NSNumber *quantity;

/**
 Product brand (default: “”). Optional.
 */
@property (nullable, nonatomic, readonly) NSString *brand;

/**
 Product variant (default: “”). Optional.
 */
@property (nullable, nonatomic, readonly) NSString *variant;

/**
 Product custom dimensions (default: {}). Optional.
 */
@property (nullable, nonatomic, strong) NSDictionary<NSNumber*, NSString*> *customDimensions;

/**
 Create a product that can be added to an ecommerce event.

 @param sku Unique identifier for the product
 @param name Product name
 @param category Product category or an array of up to 5 categories
 @param price Price of the product
 @param quantity Product quantity
 @param brand Product brand
 @param variant Product variant
 @param customDimensions Product custom dimensions
 @return An ecommerce product
 */
+ (instancetype)productWithSku:(NSString *)sku name:(nullable NSString *)name category:(nullable NSArray<NSString *>*)category price:(nullable NSString *)price quantity:(nullable NSNumber *)quantity brand:(nullable NSString *)brand variant:(nullable NSString *)variant customDimensions:(nullable NSDictionary<NSNumber*, NSString*>*)customDimensions NS_SWIFT_NAME(productWithSku(sku:name:category:price:quantity:brand:variant:customDimensions:));

/**
 Create a product that can be added to an ecommerce event. with a minimum set of mandatory parameters.
 @param sku Unique identifier for the product
 @return An ecommerce product
 */
+ (instancetype)productWithSKU:(NSString *)sku NS_SWIFT_NAME(productWithSKU(sku:));

/**
 Return YES if all mandatory properties has been set.
 */
- (BOOL)isValid;

@end

NS_ASSUME_NONNULL_END
