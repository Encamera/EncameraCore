//
//  EcommerceProducts.h
//  PiwikPROSDK
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class Product;

/**
 Product cart builder for e-commerce events.
 Contains all products that should be dispatched with e-commerce event.
 */
@interface EcommerceProducts : NSObject

/**
 A list of products.
 @see Product
 */
@property (nullable, nonatomic, strong) NSMutableDictionary *products;

/**
 Add a product.

 @param sku Unique identifier for the product
 @param name Product name
 @param category Product category or an array of up to 5 categories
 @param price Price of the product
 @param quantity Product quantity
 @param brand Product brand
 @param variant Product variant
 @param customDimensions Product custom dimensions
 @see addProductWithSku:sku:
 @see addProduct:product:
 @see addProducts:products:
 */
- (void)addProductWithSku:(NSString *)sku name:(nullable NSString *)name category:(nullable NSArray<NSString *>*)category price:(nullable NSString *)price quantity:(nullable NSNumber *)quantity brand:(nullable NSString *)brand variant:(nullable NSString *)variant customDimensions:(nullable NSDictionary<NSNumber*, NSString*>*)customDimensions NS_SWIFT_NAME(addProduct(sku:name:category:price:quantity:brand:variant:customDimensions:));

/**
 Add a product to the products list.

 @param sku The unique SKU of the product
 @see addProductWithSku:name:category:price:quantity:brand:variant:customDimensions:
 @see addProduct:product:
 @see addProducts:products:
 */
- (void)addProductWithSku:(NSString *)sku NS_SWIFT_NAME(addProductWith(sku:));

/**
 Add a product to the products list.

 @param product The product to be added to the list of products
 @see addProductWithSku:name:category:price:quantity:brand:variant:customDimensions:
 @see addProductWithSku:sku:
 @see addProducts:products:
 */
- (void)addProduct:(Product *)product NS_SWIFT_NAME(add(product:));

/**
 Add a products to the products list.

 @param products The products to be added to the list of products
 @see addProductWithSku:name:category:price:quantity:brand:variant:customDimensions:
 @see addProductWithSku:sku:
 @see addProduct:product:
 */
- (void)addProducts:(NSArray<Product *> *)products NS_SWIFT_NAME(add(products:));

/**
 Remove a product from the products list.

 @param product The product to be removed from the list of products
 @see removeProductWithSku:sku:
 */
- (void)removeProduct:(Product *)product NS_SWIFT_NAME(removeProduct(product:));

/**
 Remove a product from the products list.

 @param sku The unique SKU of the product
 @see removeProduct:product:
 */
- (void)removeProductWithSku:(NSString *)sku NS_SWIFT_NAME(removeProduct(sku:));

/**
 Clears all products from the list.

 @see removeProduct:product:
 @see removeProductWithSku:sku:
 */
- (void)clear NS_SWIFT_NAME(clear());

@end

NS_ASSUME_NONNULL_END
