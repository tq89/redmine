# Redmine Approval Workflow — Lưu trình ký & Gia hạn

Plugin bổ sung hai tính năng cho Redmine 7:

1. **Lưu trình ký** — chuỗi bước ký duyệt có thứ tự; mỗi lần ký sẽ tự đổi trạng thái công việc theo lưu trình đã thiết lập.
2. **Gia hạn công việc** — đẩy ngày hoàn thành sang mốc mới, với giới hạn số ngày tối đa cho mỗi lần do quản trị viên đặt.

## Nguyên tắc phân quyền ký duyệt

Plugin **không** tạo ra hệ thống quyền riêng cho việc ký. Quyền ký một bước
chính là quyền chuyển công việc sang trạng thái đích của bước đó, tức là
luồng công việc thiết lập tại **Quản trị → Luồng công việc**.

Về mặt kỹ thuật, mọi lần ký đều đi qua:

```ruby
issue.attributes_editable?(user) &&
  issue.new_statuses_allowed_to(user).include?(target_status)
```

Kiểm tra này được thực hiện **tường minh** trong `ApprovalsController#create`.
Lý do: `Issue#safe_attributes=` của Redmine (`app/models/issue.rb:619-623`)
âm thầm **bỏ qua** status không được phép thay vì báo lỗi — nếu dựa vào nó thì
một chữ ký trái phép sẽ trông như thành công trong khi trạng thái không đổi.

Hệ quả: muốn cấp quyền ký bước "Giám đốc duyệt" cho vai trò nào, chỉ cần cho
vai trò đó quyền chuyển sang trạng thái tương ứng trong luồng công việc.

## Cài đặt

```bash
# copy plugin vào thư mục plugins/ rồi:
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
# restart Redmine
```

Bật module **Lưu trình ký & Gia hạn** trong Cài đặt dự án → Mô-đun.

## Thiết lập

**Quản trị → Lưu trình ký**: tạo lưu trình gồm tên, tracker, dự án (để trống =
áp dụng mọi dự án), trạng thái khi bị từ chối, và danh sách bước theo thứ tự.

Lưu trình gắn với một dự án được ưu tiên hơn lưu trình chung của cùng tracker.

**Quản trị → Plugins → Cấu hình**:

| Thiết lập | Mặc định | Ý nghĩa |
|---|---|---|
| Số ngày tối đa mỗi lần gia hạn | 30 | 0 = không giới hạn |
| Số lần gia hạn tối đa | 0 | 0 = không giới hạn |
| Bắt buộc nhập lý do gia hạn | có | |

## Cách hoạt động

Tiến độ lưu trình được suy ra từ bảng `approval_signatures`, **không** từ
trạng thái công việc. Nhờ vậy một lần đổi trạng thái thủ công bên ngoài lưu
trình không thể lặng lẽ bỏ qua một bước — khi lệch, panel hiện cảnh báo.

- **Ký duyệt** bước `p`: trạng thái → status của bước `p`, con trỏ tiến lên `p+1`.
- **Từ chối** bước `p`: con trỏ lùi về `max(0, p-1)`; trạng thái về status của
  bước `p-2`, hoặc "trạng thái khi bị từ chối" nếu đang ở đầu lưu trình.

Mỗi thao tác đều tạo một journal trên công việc, nên lịch sử hiển thị đầy đủ
trong tab thông thường của Redmine.

## Quyền

| Quyền | Tác dụng |
|---|---|
| Xem lưu trình ký | Hiện panel lưu trình trên trang công việc |
| Gia hạn công việc | Cho phép bấm nút Gia hạn |

Quản lý lưu trình chỉ dành cho quản trị viên hệ thống.

## Kiểm thử

```bash
bundle exec rails test plugins/redmine_approval_workflow/test RAILS_ENV=test
```

49 test, 178 assertion.
