// Copyright 2019 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/Matrix.h"

#include <algorithm>
#include <cmath>

#include "Common/MathUtil.h"

#ifdef __aarch64__
#include <arm_neon.h>
#endif

namespace
{
// Multiply a NxM matrix by a MxP matrix.
template <int N, int M, int P, typename T>
auto MatrixMultiply(const std::array<T, N * M>& a, const std::array<T, M * P>& b)
    -> std::array<T, N * P>
{
  std::array<T, N * P> result;

#ifdef __aarch64__
  // ARM64 NEON optimization for 4x4 float matrix multiplication (most common case)
  if constexpr (N == 4 && M == 4 && P == 4 && std::is_same_v<T, float>)
  {
    // Load matrix A rows
    float32x4_t a_row0 = vld1q_f32(&a[0]);
    float32x4_t a_row1 = vld1q_f32(&a[4]);
    float32x4_t a_row2 = vld1q_f32(&a[8]);
    float32x4_t a_row3 = vld1q_f32(&a[12]);

    // Load matrix B columns
    float32x4_t b_col0 = {b[0], b[4], b[8], b[12]};
    float32x4_t b_col1 = {b[1], b[5], b[9], b[13]};
    float32x4_t b_col2 = {b[2], b[6], b[10], b[14]};
    float32x4_t b_col3 = {b[3], b[7], b[11], b[15]};

    // Compute result matrix using NEON vector operations
    float32x4_t result_row0, result_row1, result_row2, result_row3;

    // Row 0
    result_row0 = vmulq_n_f32(b_col0, vgetq_lane_f32(a_row0, 0));
    result_row0 = vmlaq_n_f32(result_row0, b_col1, vgetq_lane_f32(a_row0, 1));
    result_row0 = vmlaq_n_f32(result_row0, b_col2, vgetq_lane_f32(a_row0, 2));
    result_row0 = vmlaq_n_f32(result_row0, b_col3, vgetq_lane_f32(a_row0, 3));

    // Row 1
    result_row1 = vmulq_n_f32(b_col0, vgetq_lane_f32(a_row1, 0));
    result_row1 = vmlaq_n_f32(result_row1, b_col1, vgetq_lane_f32(a_row1, 1));
    result_row1 = vmlaq_n_f32(result_row1, b_col2, vgetq_lane_f32(a_row1, 2));
    result_row1 = vmlaq_n_f32(result_row1, b_col3, vgetq_lane_f32(a_row1, 3));

    // Row 2
    result_row2 = vmulq_n_f32(b_col0, vgetq_lane_f32(a_row2, 0));
    result_row2 = vmlaq_n_f32(result_row2, b_col1, vgetq_lane_f32(a_row2, 1));
    result_row2 = vmlaq_n_f32(result_row2, b_col2, vgetq_lane_f32(a_row2, 2));
    result_row2 = vmlaq_n_f32(result_row2, b_col3, vgetq_lane_f32(a_row2, 3));

    // Row 3
    result_row3 = vmulq_n_f32(b_col0, vgetq_lane_f32(a_row3, 0));
    result_row3 = vmlaq_n_f32(result_row3, b_col1, vgetq_lane_f32(a_row3, 1));
    result_row3 = vmlaq_n_f32(result_row3, b_col2, vgetq_lane_f32(a_row3, 2));
    result_row3 = vmlaq_n_f32(result_row3, b_col3, vgetq_lane_f32(a_row3, 3));

    // Store results
    vst1q_f32(reinterpret_cast<float*>(&result[0]), result_row0);
    vst1q_f32(reinterpret_cast<float*>(&result[4]), result_row1);
    vst1q_f32(reinterpret_cast<float*>(&result[8]), result_row2);
    vst1q_f32(reinterpret_cast<float*>(&result[12]), result_row3);

    return result;
  }
  else
#endif
  {
    // Generic implementation for non-optimized cases
    for (int n = 0; n != N; ++n)
    {
      for (int p = 0; p != P; ++p)
      {
        T temp = {};
        for (int m = 0; m != M; ++m)
        {
          temp += a[n * M + m] * b[m * P + p];
        }
        result[n * P + p] = temp;
      }
    }
  }

  return result;
}

#ifdef __aarch64__
/// ARM64 NEON optimized vector operations for common 3D math
namespace NEON_Math
{
/// Fast vector normalization using NEON
static inline Common::Vec3 FastNormalize(const Common::Vec3& v)
{
  float32x4_t vec = {v.x, v.y, v.z, 0.0f};

  // Compute dot product
  float32x4_t dot = vmulq_f32(vec, vec);
  float32x2_t sum = vadd_f32(vget_low_f32(dot), vget_high_f32(dot));
  sum = vpadd_f32(sum, sum);

  // Fast inverse square root approximation + one Newton-Raphson iteration
  float32x2_t rsqrt = vrsqrte_f32(sum);
  rsqrt = vmul_f32(rsqrt, vrsqrts_f32(vmul_f32(sum, rsqrt), rsqrt));

  // Multiply by inverse square root
  float32x4_t normalized = vmulq_n_f32(vec, vget_lane_f32(rsqrt, 0));

  Common::Vec3 result;
  vst1q_lane_f32(&result.x, normalized, 0);
  vst1q_lane_f32(&result.y, normalized, 1);
  vst1q_lane_f32(&result.z, normalized, 2);

  return result;
}

/// Fast dot product using NEON
static inline float FastDotProduct(const Common::Vec3& a, const Common::Vec3& b)
{
  float32x4_t va = {a.x, a.y, a.z, 0.0f};
  float32x4_t vb = {b.x, b.y, b.z, 0.0f};

  float32x4_t mul = vmulq_f32(va, vb);
  float32x2_t sum = vadd_f32(vget_low_f32(mul), vget_high_f32(mul));
  sum = vpadd_f32(sum, sum);

  return vget_lane_f32(sum, 0);
}

/// Fast cross product using NEON
static inline Common::Vec3 FastCrossProduct(const Common::Vec3& a, const Common::Vec3& b)
{
  float32x4_t va = {a.x, a.y, a.z, 0.0f};
  float32x4_t vb = {b.x, b.y, b.z, 0.0f};

  // Shuffle for cross product calculation
  float32x4_t va_yzx = {a.y, a.z, a.x, 0.0f};
  float32x4_t vb_yzx = {b.y, b.z, b.x, 0.0f};

  float32x4_t cross1 = vmulq_f32(va, vb_yzx);
  float32x4_t cross2 = vmulq_f32(va_yzx, vb);
  float32x4_t result = vsubq_f32(cross1, cross2);

  // Shuffle back to xyz
  Common::Vec3 output;
  output.x = vgetq_lane_f32(result, 2);
  output.y = vgetq_lane_f32(result, 0);
  output.z = vgetq_lane_f32(result, 1);

  return output;
}
}
#endif

}  // namespace

namespace Common
{
Quaternion Quaternion::Identity()
{
  return Quaternion(1, 0, 0, 0);
}

Quaternion Quaternion::RotateX(float rad)
{
  return Rotate(rad, Common::Vec3(1, 0, 0));
}

Quaternion Quaternion::RotateY(float rad)
{
  return Rotate(rad, Common::Vec3(0, 1, 0));
}

Quaternion Quaternion::RotateZ(float rad)
{
  return Rotate(rad, Common::Vec3(0, 0, 1));
}

Quaternion Quaternion::RotateXYZ(const Vec3& rads)
{
  const auto length = rads.Length();
  return length ? Common::Quaternion::Rotate(length, rads / length) :
                  Common::Quaternion::Identity();
}

Quaternion Quaternion::Rotate(float rad, const Vec3& axis)
{
  const auto sin_angle_2 = std::sin(rad / 2);

  return Quaternion(std::cos(rad / 2), axis.x * sin_angle_2, axis.y * sin_angle_2,
                    axis.z * sin_angle_2);
}

Quaternion::Quaternion(float w, float x, float y, float z) : data(x, y, z, w)
{
}

float Quaternion::Norm() const
{
  return std::sqrt(data.Dot(data));
}

Quaternion Quaternion::Normalized() const
{
  Quaternion result(*this);
  result.data /= Norm();
  return result;
}

Quaternion Quaternion::Conjugate() const
{
  return Quaternion(data.w, -1 * data.x, -1 * data.y, -1 * data.z);
}

Quaternion Quaternion::Inverted() const
{
  return Normalized().Conjugate();
}

Quaternion& Quaternion::operator*=(const Quaternion& rhs)
{
  auto& a = data;
  auto& b = rhs.data;

  data = Vec4{a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
              a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
              a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
              // W
              a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
  return *this;
}

Quaternion operator*(Quaternion lhs, const Quaternion& rhs)
{
  return lhs *= rhs;
}

Vec3 operator*(const Quaternion& lhs, const Vec3& rhs)
{
  const auto result = lhs * Quaternion(0, rhs.x, rhs.y, rhs.z) * lhs.Conjugate();
  return Vec3(result.data.x, result.data.y, result.data.z);
}

Vec3 FromQuaternionToEuler(const Quaternion& q)
{
  Vec3 result;

  const float qx = q.data.x;
  const float qy = q.data.y;
  const float qz = q.data.z;
  const float qw = q.data.w;

  const float sinr_cosp = 2 * (qw * qx + qy * qz);
  const float cosr_cosp = 1 - 2 * (qx * qx + qy * qy);
  result.x = std::atan2(sinr_cosp, cosr_cosp);

  const float sinp = 2 * (qw * qy - qz * qx);
  if (std::abs(sinp) >= 1)
    result.y = std::copysign(MathUtil::PI / 2, sinp);  // use 90 degrees if out of range
  else
    result.y = std::asin(sinp);

  const float siny_cosp = 2 * (qw * qz + qx * qy);
  const float cosy_cosp = 1 - 2 * (qy * qy + qz * qz);
  result.z = std::atan2(siny_cosp, cosy_cosp);

  return result;
}

Matrix33 Matrix33::Identity()
{
  Matrix33 mtx = {};
  mtx.data[0] = 1.0f;
  mtx.data[4] = 1.0f;
  mtx.data[8] = 1.0f;
  return mtx;
}

Matrix33 Matrix33::FromQuaternion(const Quaternion& q)
{
  const auto qx = q.data.x;
  const auto qy = q.data.y;
  const auto qz = q.data.z;
  const auto qw = q.data.w;

  return {
      1 - 2 * qy * qy - 2 * qz * qz, 2 * qx * qy - 2 * qz * qw,     2 * qx * qz + 2 * qy * qw,
      2 * qx * qy + 2 * qz * qw,     1 - 2 * qx * qx - 2 * qz * qz, 2 * qy * qz - 2 * qx * qw,
      2 * qx * qz - 2 * qy * qw,     2 * qy * qz + 2 * qx * qw,     1 - 2 * qx * qx - 2 * qy * qy,
  };
}

Matrix33 Matrix33::RotateX(float rad)
{
  const float s = std::sin(rad);
  const float c = std::cos(rad);
  Matrix33 mtx = {};
  mtx.data[0] = 1;
  mtx.data[4] = c;
  mtx.data[5] = -s;
  mtx.data[7] = s;
  mtx.data[8] = c;
  return mtx;
}

Matrix33 Matrix33::RotateY(float rad)
{
  const float s = std::sin(rad);
  const float c = std::cos(rad);
  Matrix33 mtx = {};
  mtx.data[0] = c;
  mtx.data[2] = s;
  mtx.data[4] = 1;
  mtx.data[6] = -s;
  mtx.data[8] = c;
  return mtx;
}

Matrix33 Matrix33::RotateZ(float rad)
{
  const float s = std::sin(rad);
  const float c = std::cos(rad);
  Matrix33 mtx = {};
  mtx.data[0] = c;
  mtx.data[1] = -s;
  mtx.data[3] = s;
  mtx.data[4] = c;
  mtx.data[8] = 1;
  return mtx;
}

Matrix33 Matrix33::Rotate(float rad, const Vec3& axis)
{
  const float s = std::sin(rad);
  const float c = std::cos(rad);
  Matrix33 mtx;
  mtx.data[0] = axis.x * axis.x * (1 - c) + c;
  mtx.data[1] = axis.x * axis.y * (1 - c) - axis.z * s;
  mtx.data[2] = axis.x * axis.z * (1 - c) + axis.y * s;
  mtx.data[3] = axis.y * axis.x * (1 - c) + axis.z * s;
  mtx.data[4] = axis.y * axis.y * (1 - c) + c;
  mtx.data[5] = axis.y * axis.z * (1 - c) - axis.x * s;
  mtx.data[6] = axis.z * axis.x * (1 - c) - axis.y * s;
  mtx.data[7] = axis.z * axis.y * (1 - c) + axis.x * s;
  mtx.data[8] = axis.z * axis.z * (1 - c) + c;
  return mtx;
}

Matrix33 Matrix33::Scale(const Vec3& vec)
{
  Matrix33 mtx = {};
  mtx.data[0] = vec.x;
  mtx.data[4] = vec.y;
  mtx.data[8] = vec.z;
  return mtx;
}

void Matrix33::Multiply(const Matrix33& a, const Matrix33& b, Matrix33* result)
{
  result->data = MatrixMultiply<3, 3, 3>(a.data, b.data);
}

void Matrix33::Multiply(const Matrix33& a, const Vec3& vec, Vec3* result)
{
  result->data = MatrixMultiply<3, 3, 1>(a.data, vec.data);
}

Matrix33 Matrix33::Inverted() const
{
  const auto m = [this](int x, int y) { return data[y + x * 3]; };

  const auto invdet = 1 / Determinant();

  Matrix33 result;

  const auto minv = [&result](int x, int y) -> auto& { return result.data[y + x * 3]; };

  minv(0, 0) = (m(1, 1) * m(2, 2) - m(2, 1) * m(1, 2)) * invdet;
  minv(0, 1) = (m(0, 2) * m(2, 1) - m(0, 1) * m(2, 2)) * invdet;
  minv(0, 2) = (m(0, 1) * m(1, 2) - m(0, 2) * m(1, 1)) * invdet;
  minv(1, 0) = (m(1, 2) * m(2, 0) - m(1, 0) * m(2, 2)) * invdet;
  minv(1, 1) = (m(0, 0) * m(2, 2) - m(0, 2) * m(2, 0)) * invdet;
  minv(1, 2) = (m(1, 0) * m(0, 2) - m(0, 0) * m(1, 2)) * invdet;
  minv(2, 0) = (m(1, 0) * m(2, 1) - m(2, 0) * m(1, 1)) * invdet;
  minv(2, 1) = (m(2, 0) * m(0, 1) - m(0, 0) * m(2, 1)) * invdet;
  minv(2, 2) = (m(0, 0) * m(1, 1) - m(1, 0) * m(0, 1)) * invdet;

  return result;
}

float Matrix33::Determinant() const
{
  const auto m = [this](int x, int y) { return data[y + x * 3]; };

  return m(0, 0) * (m(1, 1) * m(2, 2) - m(2, 1) * m(1, 2)) -
         m(0, 1) * (m(1, 0) * m(2, 2) - m(1, 2) * m(2, 0)) +
         m(0, 2) * (m(1, 0) * m(2, 1) - m(1, 1) * m(2, 0));
}

Matrix44 Matrix44::Identity()
{
  Matrix44 mtx = {};
  mtx.data[0] = 1.0f;
  mtx.data[5] = 1.0f;
  mtx.data[10] = 1.0f;
  mtx.data[15] = 1.0f;
  return mtx;
}

Matrix44 Matrix44::FromMatrix33(const Matrix33& m33)
{
  Matrix44 mtx;
  for (int i = 0; i < 3; ++i)
  {
    for (int j = 0; j < 3; ++j)
    {
      mtx.data[i * 4 + j] = m33.data[i * 3 + j];
    }
  }

  for (int i = 0; i < 3; ++i)
  {
    mtx.data[i * 4 + 3] = 0;
    mtx.data[i + 12] = 0;
  }
  mtx.data[15] = 1.0f;
  return mtx;
}

Matrix44 Matrix44::FromQuaternion(const Quaternion& q)
{
  return FromMatrix33(Matrix33::FromQuaternion(q));
}

Matrix44 Matrix44::FromArray(const std::array<float, 16>& arr)
{
  Matrix44 mtx;
  mtx.data = arr;
  return mtx;
}

Matrix44 Matrix44::Translate(const Vec3& vec)
{
  Matrix44 mtx = Matrix44::Identity();
  mtx.data[3] = vec.x;
  mtx.data[7] = vec.y;
  mtx.data[11] = vec.z;
  return mtx;
}

Matrix44 Matrix44::Shear(const float a, const float b)
{
  Matrix44 mtx = Matrix44::Identity();
  mtx.data[2] = a;
  mtx.data[6] = b;
  return mtx;
}

Matrix44 Matrix44::Perspective(float fov_y, float aspect_ratio, float z_near, float z_far)
{
  Matrix44 mtx{};
  const float tan_half_fov_y = std::tan(fov_y / 2);
  mtx.data[0] = 1 / (aspect_ratio * tan_half_fov_y);
  mtx.data[5] = 1 / tan_half_fov_y;
  mtx.data[10] = -(z_far + z_near) / (z_far - z_near);
  mtx.data[11] = -(2 * z_far * z_near) / (z_far - z_near);
  mtx.data[14] = -1;
  return mtx;
}

void Matrix44::Multiply(const Matrix44& a, const Matrix44& b, Matrix44* result)
{
  result->data = MatrixMultiply<4, 4, 4>(a.data, b.data);
}

Vec3 Matrix44::Transform(const Vec3& v, float w) const
{
  const auto result = MatrixMultiply<4, 4, 1>(data, {v.x, v.y, v.z, w});
  return Vec3{result[0], result[1], result[2]};
}

void Matrix44::Multiply(const Matrix44& a, const Vec4& vec, Vec4* result)
{
  result->data = MatrixMultiply<4, 4, 1>(a.data, vec.data);
}

float Matrix44::Determinant() const
{
  const auto& m = data;
  return m[12] * m[9] * m[6] * m[3] - m[8] * m[13] * m[6] * m[3] - m[12] * m[5] * m[10] * m[3] +
         m[4] * m[13] * m[10] * m[3] + m[8] * m[5] * m[14] * m[3] - m[4] * m[9] * m[14] * m[3] -
         m[12] * m[9] * m[2] * m[7] + m[8] * m[13] * m[2] * m[7] + m[12] * m[1] * m[10] * m[7] -
         m[0] * m[13] * m[10] * m[7] - m[8] * m[1] * m[14] * m[7] + m[0] * m[9] * m[14] * m[7] +
         m[12] * m[5] * m[2] * m[11] - m[4] * m[13] * m[2] * m[11] - m[12] * m[1] * m[6] * m[11] +
         m[0] * m[13] * m[6] * m[11] + m[4] * m[1] * m[14] * m[11] - m[0] * m[5] * m[14] * m[11] -
         m[8] * m[5] * m[2] * m[15] + m[4] * m[9] * m[2] * m[15] + m[8] * m[1] * m[6] * m[15] -
         m[0] * m[9] * m[6] * m[15] - m[4] * m[1] * m[10] * m[15] + m[0] * m[5] * m[10] * m[15];
}

}  // namespace Common
