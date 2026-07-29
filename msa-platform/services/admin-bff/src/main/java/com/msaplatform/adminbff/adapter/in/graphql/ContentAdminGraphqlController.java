package com.msaplatform.adminbff.adapter.in.graphql;

import org.springframework.graphql.data.method.annotation.Argument;
import org.springframework.graphql.data.method.annotation.MutationMapping;
import org.springframework.graphql.data.method.annotation.QueryMapping;
import org.springframework.stereotype.Controller;

import java.util.List;

/**
 * 콘텐츠(CMS) 관리 GraphQL 엔드포인트.
 *
 * TODO: content-service HTTP 클라이언트 연동 후 실제 데이터 반환.
 * 현재는 스키마 검증용 스텁.
 */
@Controller
public class ContentAdminGraphqlController {

    @QueryMapping
    public List<NavigationMenu> navigationMenus() {
        return List.of();
    }

    @QueryMapping
    public List<Banner> banners(@Argument String slot) {
        return List.of();
    }

    @QueryMapping
    public List<StaticPage> staticPages() {
        return List.of();
    }

    @QueryMapping
    public List<HomeSection> homeSections() {
        return List.of();
    }

    @MutationMapping
    public Banner createBanner(@Argument CreateBannerInput input) {
        throw new UnsupportedOperationException("content-service 연동 전");
    }

    @MutationMapping
    public Banner setBannerActive(@Argument String id, @Argument boolean isActive) {
        throw new UnsupportedOperationException("content-service 연동 전");
    }

    public record NavigationMenu(String id, String name, String linkUrl, int displayOrder,
                                 boolean isActive, List<NavigationMenu> children) {}

    public record Banner(String id, String slot, String title, String imageUrl, String linkUrl,
                         int displayOrder, boolean isActive) {}

    public record StaticPage(String id, String slug, String title, boolean isPublished) {}

    public record HomeSection(String id, String sectionType, String title, int displayOrder,
                              boolean isActive) {}

    public record CreateBannerInput(String slot, String title, String imageUrl, String linkUrl,
                                    Integer displayOrder) {}
}
